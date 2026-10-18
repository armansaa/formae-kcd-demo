#!/usr/bin/env bash
# render-changes.sh — sourced by reality-sync.sh and apply-stack.sh.
#
#   render_changes <resources.json>
#
# Input: a JSON array of {Type, Label, Operation, PatchDocument, OldProperties, Properties}.
# Output: markdown, one Before/After table per resource, built from the old and new properties;
# falls back to the raw patch list when the properties are missing.
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
    "$1"
}
