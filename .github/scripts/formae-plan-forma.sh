#!/usr/bin/env bash
# Plan one forma (eval + simulate) and, for a PR, post the result as a plan
# comment. A forma whose folder was deleted is planned as a destroy, using the
# forma file from $FORMAE_BASE.
# Exit status: 0 clean or changes, non-zero on eval error, drift or bad output.
#
# Usage: formae-plan-forma.sh <forma> [<pr-number> <head-sha>]
# Env:   FORMAE_CONFIG, RUNNER_TEMP, FORMAE_BASE (for deleted formae),
#        GH_TOKEN + GITHUB_REPOSITORY (to comment)
set -euo pipefail

forma=$1 pr=${2:-} head_sha=${3:-}
: "${FORMAE_CONFIG:?}" "${RUNNER_TEMP:?}"
here=$(dirname "$0")
plan_md="$RUNNER_TEMP/plan.md"

file="$forma/main.pkl"
action=apply
if [[ ! -f "$file" ]]; then
  action=destroy
  file=$(bash "$here/formae-old-forma.sh" "$forma" "${FORMAE_BASE:?deleted forma needs FORMAE_BASE}")
fi

rc=0
if ! formae eval --config "$FORMAE_CONFIG" "$file" > /dev/null 2> "$RUNNER_TEMP/eval.err"; then
  cat "$RUNNER_TEMP/eval.err"
  {
    echo ":x: **\`formae eval\` failed**"
    echo
    echo '```'
    grep -v WRN "$RUNNER_TEMP/eval.err" | tail -20
    echo '```'
  } > "$plan_md"
  rc=1
else
  if [[ $action == destroy ]]; then
    formae destroy --config "$FORMAE_CONFIG" --simulate --yes \
      --output-consumer machine --output-schema json \
      "$file" > "$RUNNER_TEMP/simulate.json" 2> "$RUNNER_TEMP/simulate.err" || true
  else
    formae apply --config "$FORMAE_CONFIG" --mode reconcile --simulate --yes \
      --output-consumer machine --output-schema json \
      "$file" > "$RUNNER_TEMP/simulate.json" 2> "$RUNNER_TEMP/simulate.err" || true
  fi
  if [[ -s "$RUNNER_TEMP/simulate.json" ]]; then
    REPORT_MD="$plan_md" bash "$here/formae-scan-report.sh" "$RUNNER_TEMP/simulate.json" "$forma" || rc=$?
  else
    cat "$RUNNER_TEMP/simulate.err"
    echo "Simulate produced no output — see the job log." > "$plan_md"
    rc=1
  fi
fi

if [[ $action == destroy ]]; then
  {
    echo ":wastebasket: **This PR deletes the forma folder.** Applying it **destroys** the resources below (the forma as of ${FORMAE_BASE:0:7})."
    echo "Destroy only runs with an explicit \`formae apply -d $forma\` after approval; a plain \`formae apply\` refuses."
    echo
    cat "$plan_md"
  } > "$plan_md.new"
  mv "$plan_md.new" "$plan_md"
fi

[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$plan_md" >> "$GITHUB_STEP_SUMMARY"
if [[ -n "$pr" ]]; then
  bash "$here/formae-plan-comment.sh" "$forma" "$pr" "$head_sha" "$plan_md"
fi
exit "$rc"
