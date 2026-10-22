#!/usr/bin/env bash
# Print the formae (folders with main.pkl under $PROJECT_DIR) affected by the
# changes between two commits, as a JSON array.
#
# Usage: formae-changed.sh [<base-sha> <head-sha>]
#   Includes formae whose folder was deleted (main.pkl gone at <head>).
#   No/zero base sha -> every forma (scheduled drift scan, manual run).
#   modules/, PklProject or the formae workflows/scripts changed -> every forma.
set -euo pipefail

: "${PROJECT_DIR:?}"
base=${1:-}
head=${2:-HEAD}

all_formae() {
  # No $PROJECT_DIR yet (every forma deleted): no formae, not an error.
  [[ -d "$PROJECT_DIR" ]] || return 0
  find "$PROJECT_DIR" -name main.pkl -exec dirname {} \; | sort -u
}

if [[ -z "$base" || "$base" =~ ^0+$ ]]; then
  dirs=$(all_formae)
else
  changed=$(git diff --name-only "$base" "$head")
  echo "Changed files:" >&2
  echo "$changed" >&2

  # Shared code changed -> every forma in the project may be affected.
  if grep -qE '^(modules/|PklProject|\.github/(workflows|scripts|actions)/formae-)' <<<"$changed"; then
    dirs=$(all_formae)
  else
    dirs=$(
      grep "^$PROJECT_DIR/" <<<"$changed" | while read -r f; do
        d=$(dirname "$f")
        # Walk up to the folder that owns main.pkl.
        while [[ "$d" == "$PROJECT_DIR"* && ! -f "$d/main.pkl" ]]; do d=$(dirname "$d"); done
        [[ -f "$d/main.pkl" ]] && echo "$d"
      done | sort -u
    ) || true
  fi
fi

# Formae whose folder was deleted: removing a forma = destroying its resources.
if [[ -n "$base" && ! "$base" =~ ^0+$ ]]; then
  deleted=$(git diff --name-only --diff-filter=D "$base" "$head" \
    | grep -E "^$PROJECT_DIR/.+/main\.pkl$" | xargs -r -n1 dirname \
    | while read -r d; do [[ -f "$d/main.pkl" ]] || echo "$d"; done) || true
  dirs=$(printf '%s\n%s\n' "${dirs:-}" "${deleted:-}" | sed '/^$/d' | sort -u)
fi

jq -Rnc '[inputs | select(length > 0)]' <<<"${dirs:-}"
