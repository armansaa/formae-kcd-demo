#!/usr/bin/env bash
# Parse a PR comment command: `formae <verb> [-d <dir>]...`.
# Only the first non-blank line counts. Prints the -d dirs as a JSON array ([] = all
# formae in the PR); exits 1 if the comment isn't a valid command.
#
# Usage: COMMENT_BODY=... formae-command.sh <verb>
set -euo pipefail

verb=$1
: "${COMMENT_BODY?}"

cmd=$(tr -d '\r' <<<"$COMMENT_BODY" | sed -n '/[^[:space:]]/{p;q;}' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
[[ "$cmd" =~ ^formae\ ${verb}((\ +-d\ +[A-Za-z0-9._/-]+)*)$ ]] || exit 1
{ grep -oE -- '-d +[A-Za-z0-9._/-]+' <<<"${BASH_REMATCH[1]}" || true; } \
  | sed -E 's/^-d +//; s#^\./##; s#/+$##' \
  | jq -Rnc '[inputs | select(length > 0)]'
