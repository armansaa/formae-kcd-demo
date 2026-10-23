#!/usr/bin/env bash
# reality-sync.sh — absorb drift for one stack (reality wins), then write the desired state back to its file.
#
#   .github/scripts/reality-sync.sh <stack-file> <stack-name>
#   .github/scripts/reality-sync.sh projects/kcd-2026/bucket/formae-demo/main.pkl kcd-2026/bucket/formae-demo
#
# From Arief's formae-kcd-demo (armansaa/formae-kcd-demo), adapted to the agent
# formae-kcd: connection from $FORMAE_CONFIG (action .github/actions/formae-agent).
#
# Flow:
#   1. simulate a soft reconcile of the stack file (machine output, JSON)
#   2. no drift                    -> status=clean     (or code-differs if file != agent)
#   3. drift, passes guardrails    -> absorb via --resolution, reviewed against the file on main
#                                     (or against the agent's desired state when main lags behind,
#                                     e.g. an open PR), wait for the command, extract --desired
#                                     into the file
#                                     -> status=absorbed
#   4. drift, hits a guardrail     -> touch nothing -> status=blocked
#
# Guardrails (there is no human approval, so these are the only brakes):
#   - only Operation "update" may be absorbed; delete/create => blocked
#   - only types listed in ALLOWED_TYPES may be absorbed
#   - one resolution must decide ALL drifted resources, so a single resource that hits a
#     guardrail stops the whole run (no partial absorb)
#
# Outputs (to $GITHUB_OUTPUT when set): status, summary (markdown path), command_id
set -euo pipefail

STACK_FILE="${1:?usage: reality-sync.sh <stack-file> <stack-name>}"
STACK="${2:?usage: reality-sync.sh <stack-file> <stack-name>}"
: "${FORMAE_CONFIG:?FORMAE_CONFIG is empty (run .github/actions/formae-agent first)}"
ALLOWED_TYPES="${ALLOWED_TYPES:-K8S::Core::ConfigMap K8S::Apps::Deployment K8S::Batch::CronJob}"
POLL_TIMEOUT="${POLL_TIMEOUT:-300}"

OUT="${RUNNER_TEMP:-/tmp}/reality-sync-${STACK//\//_}"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.md"
: > "$SUMMARY"
rm -f "$OUT/original.pkl"
trap '[[ ! -f "$OUT/original.pkl" ]] || cp "$OUT/original.pkl" "$STACK_FILE"' EXIT

out() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; echo "::notice::$1=$2"; }
finish() { out status "$1"; out summary "$SUMMARY"; exit "${2:-0}"; }
formae_m() { formae "$@" --config "$FORMAE_CONFIG" --output-consumer machine --output-schema json; }

# ---------- 1. simulate ----------
set +e
formae_m apply --mode reconcile --simulate "$STACK_FILE" > "$OUT/simulate.json" 2> "$OUT/simulate.err"
rc=$?
set -e

if [[ $rc -eq 0 ]]; then
  changes="$(jq -r '.ChangesRequired // .Simulation.ChangesRequired // false' "$OUT/simulate.json")"
  if [[ "$changes" == "true" ]]; then
    # No drift, but the file in Git differs from the agent's desired state. Happens when a
    # previous reality-sync PR is still open or was closed, a PR with a code change is not
    # applied yet, or a human edited main. The bot NEVER applies code changes: that goes
    # through a PR and `formae apply` (taufik-formae-apply).
    {
      echo "### reality-sync: \`$STACK\` — file differs from the agent, no drift"
      echo
      echo "Nothing changed outside formae. The file on \`main\` differs from the agent's desired"
      echo "state (a reality-sync PR is not merged yet, or the code was edited). The bot does not apply it;"
      echo "that goes through a PR and \`formae apply -d $(dirname "$STACK_FILE")\`."
    } >> "$SUMMARY"
    finish code-differs
  fi
  echo "### reality-sync: \`$STACK\` — clean, no drift" >> "$SUMMARY"
  finish clean
fi

if ! jq -e '.data.ObservationID // empty' "$OUT/simulate.json" > /dev/null 2>&1; then
  echo "Simulate failed, and not because of drift:" >&2
  cat "$OUT/simulate.json" "$OUT/simulate.err" >&2 || true
  finish error 1
fi

cp "$STACK_FILE" "$OUT/original.pkl"

# ---------- 2. read drift + guardrails ----------
OBS_ID="$(jq -r '.data.ObservationID' "$OUT/simulate.json")"
jq -c '[.data.ModifiedStacks[]?.ModifiedResources[]?]' "$OUT/simulate.json" > "$OUT/resources.json"
count="$(jq 'length' "$OUT/resources.json")"
[[ "$count" -gt 0 ]] || { echo "ObservationID without resources" >&2; finish error 1; }

blocked_reasons="$(jq -r --arg allowed "$ALLOWED_TYPES" '
  ($allowed | split(" ")) as $ok
  | .[] as $r
  | $r
  | if (.Operation | ascii_downcase) != "update" then
      "- `\(.Type)` `\(.Label)`: operation `\(.Operation)` (not update) — out-of-band deletions/creations are never absorbed automatically"
    elif ($ok | index($r.Type)) == null then
      "- `\(.Type)` `\(.Label)`: type is not in the allowlist"
    else empty end' "$OUT/resources.json")"

render_changes() {
  jq -r '
    def leaves: [paths(scalars) as $p
      | {key: ($p | map(if type == "number" then "[\(.)]" else ".\(.)" end) | join("") | ltrimstr(".")),
         value: getpath($p)}] | from_entries;
    def cell($m; $k): if $m | has($k) then "`\($m[$k] | tostring | gsub("\\|"; "\\|"))`" else "_not set_" end;
    .[]
    | ((.OldProperties // {}) | leaves) as $before
    | ((.Properties // {}) | leaves) as $after
    | [ ($before + $after | keys[]) as $k
        | select(($before | has($k) | not) or ($after | has($k) | not) or $before[$k] != $after[$k])
        | "| `\($k)` | \(cell($before; $k)) | \(cell($after; $k)) |" ] as $rows
    | "**`\(.Type)` `\(.Label)`** (\(.Operation))",
      "",
      ( if ($rows | length) > 0 then "| Field | Before | After |", "|---|---|---|", $rows[]
        else ( (.PatchDocument // [])[]? |
               "- `\(.op)` `\(.path)`" + (if has("value") then " → `\(.value | tostring)`" else "" end) ) end ),
      ""' \
    "$OUT/resources.json"
}

if [[ -n "$blocked_reasons" ]]; then
  {
    echo "### reality-sync: \`$STACK\` — drift BLOCKED by guardrails, nothing was changed"
    echo
    echo "ObservationID: \`$OBS_ID\`"
    echo
    echo "Reasons:"
    echo "$blocked_reasons"
    echo
    echo "Observed drift:"
    render_changes
    echo
    echo "Decide in a PR: update \`$STACK_FILE\` to match the cloud and comment"
    echo "\`formae apply -d $(dirname "$STACK_FILE") --absorb\` (reality wins)."
    echo "A deleted resource can only come back by re-applying the code (\`formae apply -d $(dirname "$STACK_FILE")\`)."
  } >> "$SUMMARY"
  finish blocked
fi

# ---------- 3. absorb via --resolution ----------
review() {
  jq -n --arg obs "$OBS_ID" --slurpfile r "$OUT/resources.json" '{
    ObservationID: $obs,
    IdempotencyKey: ("reality-sync-" + $obs),
    Decisions: [ $r[0][] | {ResourceID: .ResourceID, Action: "absorb"} ]
  }' > "$OUT/resolution.json"
  formae_m apply --mode reconcile --simulate --yes \
    --resolution "$OUT/resolution.json" \
    "$STACK_FILE" > "$OUT/review.json"
}

# Review against the file on main first: it carries the forma's own schema (e.g. the container
# subclass in kube-manifest/promo and mario), and a rendered copy with the plain plugin schema is
# rejected as a schema edit. Fall back to the agent's desired state only when main lags behind
# the agent on the drifted field (e.g. an unmerged bot PR), which the agent also rejects as an edit.
if ! review; then
  if ! jq -e '.data.Code == "decision-edit-conflict"' "$OUT/review.json" > /dev/null 2>&1; then
    echo "Review of the resolution failed:" >&2; cat "$OUT/review.json" >&2; finish error 1
  fi
  echo "Review against the file on main conflicts, retrying against the agent's desired state:" >&2
  cat "$OUT/review.json" >&2
  "$(dirname "$0")/formae-extract-desired.sh" "$STACK" "$OUT/desired.pkl"
  cp "$OUT/desired.pkl" "$STACK_FILE"
  set +e
  formae_m apply --mode reconcile --simulate "$STACK_FILE" > "$OUT/simulate.json" 2> "$OUT/simulate.err"
  set -e
  if ! jq -e '.data.ObservationID // empty' "$OUT/simulate.json" > /dev/null 2>&1; then
    echo "No drift observation against the agent's desired state:" >&2
    cat "$OUT/simulate.json" "$OUT/simulate.err" >&2 || true
    finish error 1
  fi
  OBS_ID="$(jq -r '.data.ObservationID' "$OUT/simulate.json")"
  jq -c '[.data.ModifiedStacks[]?.ModifiedResources[]?]' "$OUT/simulate.json" > "$OUT/resources.json"
  review || { echo "Review of the resolution failed:" >&2; cat "$OUT/review.json" >&2; finish error 1; }
fi
REVIEW_ID="$(jq -r '.Review.ReviewID // empty' "$OUT/review.json")"
[[ -n "$REVIEW_ID" ]] || { echo "Review returned no ReviewID:" >&2; cat "$OUT/review.json" >&2; finish error 1; }
jq --arg review "$REVIEW_ID" '. + {ReviewID: $review}' "$OUT/resolution.json" > "$OUT/resolution.final.json"

formae_m apply --mode reconcile --yes \
  --resolution "$OUT/resolution.final.json" \
  --message "reality-sync: absorb drift ${STACK} (${GITHUB_RUN_ID:-manual})" \
  "$STACK_FILE" > "$OUT/apply.json" \
  || { echo "Apply with the resolution was rejected:" >&2; cat "$OUT/apply.json" >&2; finish error 1; }

CMD_ID="$(jq -r '.CommandId // empty' "$OUT/apply.json")"
[[ -n "$CMD_ID" ]] || { echo "Apply returned no CommandId:" >&2; cat "$OUT/apply.json" >&2; finish error 1; }
out command_id "$CMD_ID"

deadline=$(( SECONDS + POLL_TIMEOUT ))
state=""
while (( SECONDS < deadline )); do
  formae_m command status "$CMD_ID" > "$OUT/status.json"
  state="$(jq -r '.Commands[0].State // empty' "$OUT/status.json")"
  case "$state" in
    Success) break ;;
    Failed|Canceled|Cancelled) echo "Command $CMD_ID ended: $state" >&2; cat "$OUT/status.json" >&2; finish error 1 ;;
  esac
  sleep 5
done
[[ "$state" == "Success" ]] || { echo "Timed out waiting for $CMD_ID (state=$state)" >&2; finish error 1; }

# ---------- 4. write the desired state back to the file ----------
# formae-extract-desired.sh instead of `formae extract --desired`: the plain command fails on
# fields outside the plugin schema, Resolvables and stack labels with "/" (see the script).
# If it still fails, the run stops as an error: the agent has absorbed, Git has not. A human
# has to look at it.
"$(dirname "$0")/formae-extract-desired.sh" "$STACK" "$OUT/extracted.pkl"
cp "$OUT/extracted.pkl" "$STACK_FILE"
rm -f "$OUT/original.pkl"

{
  echo "## reality-sync: drift absorbed in \`$STACK\` (reality wins)"
  echo
  echo "The changes below happened **outside formae** (kubectl/console) and the agent has"
  echo "recorded them as desired intent. This PR brings Git in line with reality."
  echo
  render_changes
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| ObservationID | \`$OBS_ID\` |"
  echo "| CommandId formae | \`$CMD_ID\` |"
  echo "| Run | ${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-} |"
  echo
  echo "Merge it after the bot's \`formae plan\` comment shows NO CHANGES (the agent already has"
  echo "this state). Disagree? Close this PR and open one with the code you want, then"
  echo "\`formae apply -d $(dirname "$STACK_FILE")\`: because the drift was already absorbed, formae"
  echo "treats it as an ordinary code change (code wins)."
} >> "$SUMMARY"
finish absorbed
