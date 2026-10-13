#!/usr/bin/env bash
# reality-sync.sh — absorb drift for one stack (reality wins), then write the desired state back to its file.
#
#   scripts/reality-sync.sh <stack-file> <stack-name>
#   scripts/reality-sync.sh stacks/kcd-demo-app.pkl kcd-demo-app
#
# Flow:
#   1. simulate a soft reconcile of the stack file (machine output, JSON)
#   2. no drift                    -> status=clean     (or code-differs if file != agent)
#   3. drift, passes guardrails    -> absorb via --resolution against the agent's desired state
#                                     (not the Git file, which may lag behind an open PR),
#                                     wait for the command, extract --desired into the file
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
PROFILE="${FORMAE_PROFILE:-ci}"
ALLOWED_TYPES="${ALLOWED_TYPES:-K8S::Core::ConfigMap K8S::Apps::Deployment K8S::Batch::CronJob}"
POLL_TIMEOUT="${POLL_TIMEOUT:-300}"

OUT="${RUNNER_TEMP:-/tmp}/reality-sync-${STACK}"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.md"
: > "$SUMMARY"
rm -f "$OUT/original.pkl"
trap '[[ ! -f "$OUT/original.pkl" ]] || cp "$OUT/original.pkl" "$STACK_FILE"' EXIT

out() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; echo "::notice::$1=$2"; }
finish() { out status "$1"; out summary "$SUMMARY"; exit "${2:-0}"; }
formae_m() { formae "$@" --profile "$PROFILE" --output-consumer machine --output-schema json; }

# ---------- 1. simulate ----------
set +e
formae_m apply --mode reconcile --simulate "$STACK_FILE" > "$OUT/simulate.json" 2> "$OUT/simulate.err"
rc=$?
set -e

if [[ $rc -eq 0 ]]; then
  changes="$(jq -r '.ChangesRequired // .Simulation.ChangesRequired // false' "$OUT/simulate.json")"
  if [[ "$changes" == "true" ]]; then
    # No drift, but the file in Git differs from the agent's desired state. Happens when a
    # previous reality-sync PR is still open or was closed, or a human edited main.
    # The bot NEVER applies code changes; that is a human decision.
    {
      echo "### reality-sync: \`$STACK\` — file differs from the agent, no drift"
      echo
      echo "Nothing changed outside formae. The file on \`main\` differs from the agent's desired"
      echo "state (a reality-sync PR is not merged yet, or the code was edited). The bot does not apply it."
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
formae extract --desired --yes --profile "$PROFILE" --query "stack:${STACK}" "$OUT/desired.pkl"
cp "$OUT/desired.pkl" "$STACK_FILE"
set +e
formae_m apply --mode reconcile --simulate "$STACK_FILE" > "$OUT/simulate.json" 2> "$OUT/simulate.err"
set -e
if ! jq -e '.data.ObservationID // empty' "$OUT/simulate.json" > /dev/null 2>&1; then
  echo "No drift observation against the agent's desired state:" >&2
  cat "$OUT/simulate.json" "$OUT/simulate.err" >&2 || true
  finish error 1
fi

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
    echo "Decide manually: absorb (reality wins) or revert (code wins) with"
    echo "\`formae apply --mode reconcile $STACK_FILE\` from a machine connected to the agent."
  } >> "$SUMMARY"
  finish blocked
fi

# ---------- 3. absorb via --resolution ----------
jq -n --arg obs "$OBS_ID" --slurpfile r "$OUT/resources.json" '{
  ObservationID: $obs,
  IdempotencyKey: ("reality-sync-" + $obs),
  Decisions: [ $r[0][] | {ResourceID: .ResourceID, Action: "absorb"} ]
}' > "$OUT/resolution.json"

formae_m apply --mode reconcile --simulate --yes \
  --resolution "$OUT/resolution.json" \
  "$STACK_FILE" > "$OUT/review.json" \
  || { echo "Review of the resolution failed:" >&2; cat "$OUT/review.json" >&2; finish error 1; }
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
# If extract fails (e.g. a field outside the plugin schema, see the Cloud SQL findings), the run
# stops as an error: the agent has absorbed, Git has not. A human has to look at it.
formae extract --desired --yes --profile "$PROFILE" --query "stack:${STACK}" "$OUT/extracted.pkl"
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
  echo "Disagree? Close this PR, then apply \`main\` manually from a machine connected to the"
  echo "agent: \`formae apply --mode reconcile $STACK_FILE\`. Because the drift was already"
  echo "absorbed, formae shows it as an ordinary code change (code wins)."
} >> "$SUMMARY"
finish absorbed
