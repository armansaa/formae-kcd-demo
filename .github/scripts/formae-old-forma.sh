#!/usr/bin/env bash
# Print the path of a forma's main.pkl as it was at <base>, for formae whose
# folder was deleted in this change (removing the folder = destroying its
# resources, and `formae destroy` needs the forma file).
#
# The base commit is checked out once per job as a git worktree under
# $RUNNER_TEMP, so the old forma resolves its own modules/ and PklProject.
#
# Usage: formae-old-forma.sh <forma-dir> <base-sha>
set -euo pipefail

forma=$1 base=$2
: "${RUNNER_TEMP:?}"
wt="$RUNNER_TEMP/formae-base"

if [[ ! -d "$wt" ]]; then
  git worktree add --detach --quiet "$wt" "$base" >&2
fi
if [[ ! -f "$wt/$forma/main.pkl" ]]; then
  echo "no $forma/main.pkl at ${base:0:7}" >&2
  exit 1
fi
echo "$wt/$forma/main.pkl"
