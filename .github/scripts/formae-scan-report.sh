#!/usr/bin/env bash
# Render `formae apply --simulate --output-consumer machine` JSON into a
# readable report on stdout (and $GITHUB_STEP_SUMMARY when set).
#
# Usage: formae-scan-report.sh <result.json> <forma-path>
#
# Exit codes:
#   0  no changes, or changes coming from the code (expected in a PR)
#   2  drift: the stack was modified outside formae since the last reconcile
#   3  unknown/unparseable output
#
# Shapes handled (formae pkg/api/model):
#   Simulation             {ChangesRequired, Command{ResourceUpdates[], StackUpdates[], TargetUpdates[]}}
#   SubmitCommandResponse  {Review{Observations[]}, Simulation{...}}
#   ErrorResponse          {error, data{ModifiedStacks{<stack>{ModifiedResources[]}}}}
set -euo pipefail

json_file=$1
forma=$2
# Markdown goes to $REPORT_MD when set (e.g. for a PR comment), else to the
# job summary.
summary=${REPORT_MD:-${GITHUB_STEP_SUMMARY:-/dev/null}}
# $REPORT_MD holds one forma's report (callers reuse the path), so start it
# fresh; the job summary keeps appending.
[[ -n "${REPORT_MD:-}" ]] && : > "$REPORT_MD"

if ! jq -e . "$json_file" >/dev/null 2>&1; then
  echo "::error title=formae scan::${forma}: simulate output is not JSON"
  cat "$json_file"
  exit 3
fi

# Normalise the three shapes into one object.
report=$(jq -c '
  def patch: (if type == "string" then fromjson else . end) // [];
  # Fields the cloud bumps on every write; not changes anyone made.
  def volatile: ["/updated", "/timeCreated", "/etag", "/metageneration", "/generation", "/settings/settingsVersion"];
  def ops(p): p | patch | map(select(.path as $p | volatile | index($p) | not))
    | map("    \(.op) \(.path)" + (if has("value") then " = \(.value | tojson)" else "" end));
  def sym: {"create":"+","update":"~","delete":"-","replace":"±","adopt":"⇢","adopt+update":"⇢~"}[. // ""] // "•";
  # JSON pointer ("/a/b/0") -> getpath array.
  def ptr(p): p | ltrimstr("/") | split("/") | map(if test("^[0-9]+$") then tonumber else . end);
  # A replace comes as a delete + create sharing a GroupId; the delete carries
  # CreateOnlyPatch (the create-only fields that force it) and the old values.
  def replaced_groups(ru):
    [ru[] | select(.GroupId != null)] | group_by(.GroupId)
    | map(select((map(.Operation) | index("delete")) != null and (map(.Operation) | index("create")) != null))
    | map(.[0].GroupId);
  def replace_detail(d):
    [(d.CreateOnlyPatch // [])[] | .path as $p | .value as $v
      | "    ~ \($p): \((d.Properties // {}) | getpath(ptr($p)) | tojson) -> \($v | tojson)   (create-only: forces replacement)"];

  (if has("Simulation") then .Simulation elif has("ChangesRequired") then . else null end) as $sim
  | {
      error: (.error // null),
      changes_required: ($sim.ChangesRequired // false),
      changes: [
        (($sim.Command.StackUpdates  // [])[] | {sym: (.Operation | sym), op: .Operation, kind: "stack",  label: .StackLabel,  detail: []}),
        (($sim.Command.TargetUpdates // [])[] | {sym: (.Operation | sym), op: .Operation, kind: "target", label: .TargetLabel, detail: []}),
        (($sim.Command.ResourceUpdates // []) as $ru | replaced_groups($ru) as $rg
          | ($ru[] | select((.GroupId as $g | $rg | index($g)) == null)
            # Moving out of $unmanaged = adopting a resource found by `formae import`;
            # with an empty patch nothing changes in the cloud.
            | (if .OldStackName == "$unmanaged" then
                 (if ((.PatchDocument | patch) | length) == 0 then "adopt" else "adopt+update" end)
               else .Operation end) as $op
            | {sym: ($op | sym), op: $op, kind: .ResourceType, label: (.ResourceLabel // .ResourceId), detail: ops(.PatchDocument)}),
            # delete + create of one resource: shown once, as a replace.
            ([$ru[] | select((.GroupId as $g | $rg | index($g)) != null)] | group_by(.GroupId)[]
              | (map(select(.Operation == "delete"))[0]) as $d
              | (map(select(.Operation == "create"))[0]) as $c
              | {sym: ("replace" | sym), op: "replace", kind: $c.ResourceType,
                 label: ($c.ResourceLabel // $c.ResourceId), detail: replace_detail($d)}))
      ],
      drift: [
        (.data.ModifiedStacks // {} | to_entries[] | .key as $stack | .value.ModifiedResources[]
          | {sym: (.Operation | sym), op: .Operation, stack: $stack, kind: .Type, label: .Label,
             external: (.ExternalChangesOnly // false), detail: ops(.PatchDocument)}),
        ((.Review.Observations // [])[]
          | {sym: (.Kind | sym), op: .Kind, stack: .Stack, kind: .Type, label: .Label, external: true, detail: []})
      ]
    }
    # `accept`: the agent re-records a cloud-managed value the code does not
    # declare (e.g. Cloud SQL settingsVersion). Nothing changes in the cloud,
    # so it is not a change to review.
    | .accepted = [.changes[] | select(.op == "accept")]
    | .changes = [.changes[] | select(.op != "accept")]' "$json_file")

n_changes=$(jq '.changes | length' <<<"$report")
n_drift=$(jq '.drift | length' <<<"$report")
err=$(jq -r '.error // empty' <<<"$report")

echo "=================================================================="
echo " formae scan: ${forma}"
echo "=================================================================="

{
  echo "### \`${forma}\`"
  echo
} >>"$summary"

if (( n_drift > 0 )); then
  echo "DRIFT: ${n_drift} resource(s) changed outside formae since the last reconcile"
  echo
  jq -r '.drift[] | "  \(.sym) \(.op) \(.kind) \(.label)  [stack: \(.stack)]\(if .external then " (out-of-band)" else "" end)", .detail[]' <<<"$report"
  echo
  # Policy for this repo: reality wins. Never revert drift by re-applying old code.
  echo "Reality wins here: update the code to the values above, push, then comment"
  echo "\`formae apply -d ${forma} --absorb\`. Do not re-apply the old code (that would revert)."
  {
    echo ":warning: **Drift** — ${n_drift} resource(s) changed outside formae since the last reconcile."
    echo "Reality wins: update the code to match the cloud, push, then comment \`formae apply -d ${forma} --absorb\` (accepts the cloud state; nothing in the cloud changes)."
    echo
    echo "| | Operation | Type | Label | Stack |"
    echo "|---|---|---|---|---|"
    jq -r '.drift[] | "| \(.sym) | \(.op) | `\(.kind)` | `\(.label)` | `\(.stack)` |"' <<<"$report"
    echo
    echo '<details><summary>Changed fields</summary>'
    echo
    echo '```'
    jq -r '.drift[] | "\(.sym) \(.kind) \(.label)", .detail[]' <<<"$report"
    echo '```'
    echo '</details>'
    echo
  } >>"$summary"
  echo "::error title=formae drift::${forma}: ${n_drift} resource(s) drifted from the stack state"
  exit 2
fi

if [[ -n "$err" ]]; then
  echo "::error title=formae scan::${forma}: ${err}"
  jq . "$json_file"
  exit 3
fi

n_accepted=$(jq '.accepted | length' <<<"$report")
if [[ $(jq -r .changes_required <<<"$report") != "true" || "$n_changes" == 0 ]]; then
  echo "NO CHANGES: code matches the stack state and the cloud."
  echo ":white_check_mark: **No changes** — code matches reality." >>"$summary"
  if (( n_accepted > 0 )); then
    labels=$(jq -r '[.accepted[] | "`\(.label)`"] | join(", ")' <<<"$report")
    echo "  (${n_accepted} resource(s) only have cloud-managed values to re-record, e.g. settingsVersion)"
    {
      echo
      echo "<sub>The agent will re-record cloud-managed values (e.g. Cloud SQL \`settingsVersion\`) for ${labels} on the next apply. Nothing changes in the cloud.</sub>"
    } >>"$summary"
  fi
  echo >>"$summary"
  exit 0
fi

counts=$(jq -r '[.changes[].op] | group_by(.) | map("\(length) to \(.[0])") | join(", ")' <<<"$report")
echo "CHANGES: ${counts}"
echo
jq -r '.changes[] | "  \(.sym) \(.op) \(.kind) \(.label)", .detail[]' <<<"$report"
echo
echo "Applying this forma would make the changes above."
{
  echo ":pencil2: **Changes** — ${counts}"
  echo
  echo "| | Operation | Type | Label |"
  echo "|---|---|---|---|"
  jq -r '.changes[] | "| \(.sym) | \(.op) | `\(.kind)` | `\(.label)` |"' <<<"$report"
  echo
  echo '<details><summary>Changed fields</summary>'
  echo
  echo '```'
  jq -r '.changes[] | "\(.sym) \(.kind) \(.label)", .detail[]' <<<"$report"
  echo '```'
  echo '</details>'
  echo
} >>"$summary"
echo "::warning title=formae changes::${forma}: ${counts}"
