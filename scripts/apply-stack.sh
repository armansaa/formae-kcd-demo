#!/usr/bin/env bash
# apply-stack.sh — apply one stack file from Git to the agent (code wins).
#
#   scripts/apply-stack.sh <stack-file>
#   scripts/apply-stack.sh stacks/kcd-demo-app.pkl
#
# Flow:
#   1. simulate a soft reconcile of the stack file (machine output, JSON)
#   2. nothing to change           -> status=unchanged (e.g. a merged reality-sync PR: the agent
#                                     already holds that state)
#   3. drift outside formae         -> touch nothing -> status=drift (exit 1). reality-sync, or a
#                                     human, has to decide on the drift first
#   4. code changes                 -> apply (soft reconcile, never --force), wait for the
#                                     command -> status=applied
#
# Outputs (to $GITHUB_OUTPUT when set): status, summary (markdown path), command_id
set -euo pipefail

STACK_FILE="${1:?usage: apply-stack.sh <stack-file>}"
PROFILE="${FORMAE_PROFILE:-ci}"
POLL_TIMEOUT="${POLL_TIMEOUT:-300}"

OUT="${RUNNER_TEMP:-/tmp}/apply-$(basename "$STACK_FILE" .pkl)"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.md"
: > "$SUMMARY"

out() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; echo "::notice::$1=$2"; }
finish() { out status "$1"; out summary "$SUMMARY"; exit "${2:-0}"; }
formae_m() { formae "$@" --profile "$PROFILE" --output-consumer machine --output-schema json; }
source "$(dirname "$0")/render-changes.sh"

# ---------- 1. simulate ----------
set +e
formae_m apply --mode reconcile --simulate "$STACK_FILE" > "$OUT/simulate.json" 2> "$OUT/simulate.err"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  if jq -e '.data.ObservationID // empty' "$OUT/simulate.json" > /dev/null 2>&1; then
    jq -c '[.data.ModifiedStacks[]?.ModifiedResources[]?]' "$OUT/simulate.json" > "$OUT/resources.json"
    {
      echo "### apply: \`$STACK_FILE\` — NOT applied, the cluster has unresolved drift"
      echo
      echo "Something changed outside formae since the last reconcile. A soft reconcile refuses to"
      echo "overwrite it. Let reality-sync absorb it (or decide by hand), then run this workflow again."
      echo
      render_changes "$OUT/resources.json"
    } >> "$SUMMARY"
    finish drift 1
  fi
  echo "Simulate failed, and not because of drift:" >&2
  cat "$OUT/simulate.json" "$OUT/simulate.err" >&2 || true
  finish error 1
fi

changes="$(jq -r '[.ChangesRequired, .Simulation.ChangesRequired, false] | map(select(. != null)) | .[0]' "$OUT/simulate.json")"
if [[ "$changes" != "true" ]]; then
  echo "### apply: \`$STACK_FILE\` — nothing to apply, the agent already matches Git" >> "$SUMMARY"
  finish unchanged
fi

jq -c '[.Command.ResourceUpdates[]? | select(.Operation != "accept")
        | {Type: .ResourceType, Label: .ResourceLabel, Operation, PatchDocument, OldProperties, Properties}]' \
  "$OUT/simulate.json" > "$OUT/resources.json"

# ---------- 2. apply ----------
formae_m apply --mode reconcile --yes \
  --message "apply: ${STACK_FILE} @ ${GITHUB_SHA:0:7} (${GITHUB_RUN_ID:-manual})" \
  "$STACK_FILE" > "$OUT/apply.json" \
  || { echo "Apply was rejected:" >&2; cat "$OUT/apply.json" >&2; finish error 1; }

CMD_ID="$(jq -r '.CommandId // .Command.CommandId // empty' "$OUT/apply.json")"
[[ -n "$CMD_ID" ]] || { echo "Apply returned no CommandId:" >&2; cat "$OUT/apply.json" >&2; finish error 1; }
out command_id "$CMD_ID"

deadline=$(( SECONDS + POLL_TIMEOUT ))
state=""
while (( SECONDS < deadline )); do
  formae_m command status "$CMD_ID" > "$OUT/status.json"
  state="$(jq -r '.Commands[0].State // empty' "$OUT/status.json")"
  case "$state" in
    Success) break ;;
    Failed|Canceled|Cancelled)
      echo "Command $CMD_ID ended: $state" >&2
      jq -r '.Commands[0].ResourceUpdates[]? | select(.State == "Failed")
             | "  \(.ResourceLabel) \(.Operation): \(.ErrorMessage)"' "$OUT/status.json" >&2 || true
      finish error 1 ;;
  esac
  sleep 5
done
[[ "$state" == "Success" ]] || { echo "Timed out waiting for $CMD_ID (state=$state)" >&2; finish error 1; }

{
  echo "## apply: \`$STACK_FILE\` (code wins)"
  echo
  echo "The cluster now matches \`main\`."
  echo
  if [[ "$(jq 'length' "$OUT/resources.json")" -gt 0 ]]; then
    render_changes "$OUT/resources.json"
  else
    echo "No resource changed (the agent recorded the file without writing to the provider)."
    echo
  fi
  echo "| | |"
  echo "|---|---|"
  echo "| CommandId formae | \`$CMD_ID\` |"
  echo "| Commit | \`${GITHUB_SHA:-local}\` |"
} >> "$SUMMARY"
finish applied
