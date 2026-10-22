#!/usr/bin/env bash
# Make the agent aware of cloud resources a forma declares but the agent
# doesn't know yet (e.g. created before formae, or by another agent), so the
# next apply adopts them instead of creating duplicates.
#
# How: one forced discovery run on the agent (POST /api/v1/admin/discover;
# scheduled discovery stays off, and the agent only discovers the types in its
# resourceTypesToDiscover), then wait until each missing resource shows up as
# unmanaged with the same type, target and label. Nothing changes in the cloud;
# the adoption itself happens on the next `formae apply`.
#
# Usage: formae-import.sh <forma>...
# Env:   FORMAE_CONFIG, FORMAE_AGENT_USERNAME, FORMAE_AGENT_PASSWORD, RUNNER_TEMP
# Writes a markdown report to $RUNNER_TEMP/import.md. Exit 1 if any resource
# could not be matched.
set -euo pipefail

: "${FORMAE_CONFIG:?}" "${RUNNER_TEMP:?}"
AGENT=${FORMAE_AGENT_API:-http://127.0.0.1:49684/api/v1}
TIMEOUT=${FORMAE_IMPORT_TIMEOUT:-600}
out="$RUNNER_TEMP/import.md"
want="$RUNNER_TEMP/import-want.jsonl"
: > "$want"

# Desired resources: forma, type, label, target and the cloud identifier
# (the property named by the schema's Identifier, e.g. `name`).
for forma in "$@"; do
  # A forma whose folder this PR deletes is a destroy, nothing to import.
  [[ -f "$forma/main.pkl" ]] || { echo "skip $forma (folder deleted in this PR)" >&2; continue; }
  formae eval --config "$FORMAE_CONFIG" --output-consumer machine --output-schema json \
    "$forma/main.pkl" 2>/dev/null \
    | jq -c --arg forma "$forma" '.Resources[]
        | {forma: $forma, type: .Type, label: .Label, target: .Target,
           id: (.Properties[.Schema.Identifier // "name"] // "" | tostring)}' >> "$want"
done

# What the agent knows about one desired resource:
#   managed:<stack> | unmanaged | label:<discovered label> | missing
lookup() {
  local type=$1 label=$2 target=$3 id=$4 inv
  inv=$(formae inventory resources --config "$FORMAE_CONFIG" --query "type:$type" \
          --max-results 0 --output-consumer machine --output-schema json 2>/dev/null || echo '{}')
  jq -r --arg l "$label" --arg t "$target" --arg id "$id" '
    [.Resources[]? | select(.Target == $t)] as $rs
    | ([$rs[] | select(.Label == $l)] | first) as $hit
    | if $hit then (if $hit.Managed then "managed:\($hit.Stack)" else "unmanaged" end)
      else
        ([$rs[] | select(($id != "") and ((.NativeID // "") as $n
            | $n == $id or ($n | endswith("/" + $id)) or ($n | endswith(":" + $id))))] | first) as $byid
        | if $byid then "label:\($byid.Label)" else "missing" end
      end' <<<"$inv"
}

status() {
  jq -c '.' "$want" | while read -r r; do
    s=$(lookup "$(jq -r .type <<<"$r")" "$(jq -r .label <<<"$r")" \
               "$(jq -r .target <<<"$r")" "$(jq -r .id <<<"$r")")
    jq -c --arg s "$s" '. + {status: $s}' <<<"$r"
  done
}

current=$(status)
if grep -q '"status":"missing"' <<<"$current"; then
  echo "Triggering one discovery run on the agent"
  curl -fsS -X POST -u "$FORMAE_AGENT_USERNAME:$FORMAE_AGENT_PASSWORD" "$AGENT/admin/discover" > /dev/null
  deadline=$(( $(date +%s) + TIMEOUT ))
  while grep -q '"status":"missing"' <<<"$current" && (( $(date +%s) < deadline )); do
    sleep 15
    current=$(status)
    echo "still missing: $(grep -c '"status":"missing"' <<<"$current" || true)"
  done
fi

failed=0
{
  echo "## formae import"
  echo
  echo "| Forma | Type | Label | Result |"
  echo "|---|---|---|---|"
  while read -r r; do
    s=$(jq -r .status <<<"$r")
    case "$s" in
      managed:*)  res=":white_check_mark: already managed (stack \`${s#managed:}\`)" ;;
      unmanaged)  res=":inbox_tray: found in the cloud — the next \`formae apply\` adopts it, no re-create" ;;
      label:*)    res=":warning: found, but discovered as label \`${s#label:}\` — set \`alias = \"${s#label:}\"\` on this resource (or use that label), then import again"; failed=1 ;;
      *)          res=":x: not found — does it exist in the cloud, and is its type in the agent's \`resourceTypesToDiscover\`?"; failed=1 ;;
    esac
    printf '| `%s` | `%s` | `%s` | %s |\n' "$(jq -r .forma <<<"$r")" "$(jq -r .type <<<"$r")" "$(jq -r .label <<<"$r")" "$res"
  done <<<"$current"
} > "$out"
cat "$out"
exit "$failed"
