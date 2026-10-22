#!/usr/bin/env bash
# formae-extract-desired.sh — write a stack's desired state (agent) as a forma
# file. Same result as `formae extract --desired`, with workarounds for what
# makes that command fail on our formae (formae 0.90.5, gcp 0.1.18, k8s 0.1.13):
#
#   1. Fields the agent stores but the plugin schema doesn't declare
#      (GCS iamConfiguration.bucketPolicyOnly, Cloud SQL
#      backupConfiguration.replicationLogArchivingEnabled, ...):
#      "Unsupported desired declaration fields". They are pruned against each
#      resource's Schema.Fields.
#   2. Resolvable values (e.g. metadata.namespace -> the Namespace resource):
#      the k8s generator throws "Duplicate Resolvable Type URI". They are
#      rendered by this script as `new formae.Resolvable { ... }` instead.
#   3. References to resources outside the stack ($ref formae://<ksuid>, e.g.
#      the GKE target's endpoint/CA -> the discovered cluster): rendered as
#      `throw("Unresolved desired reference ...")`. Turned into Resolvables by
#      looking the KSUID up in the agent's inventory.
#   4. Stack labels with "/" become invalid Pkl identifiers
#      (`local kcd2026/bucket/x = ...`): quoted with backticks.
#
# Flow: extract --desired --output-schema json -> fix the JSON -> extract
# --from-json (renders Pkl offline) -> fix the Pkl.
#
#   .github/scripts/formae-extract-desired.sh <stack-label> <out.pkl>
#
# Env: FORMAE_CONFIG, FORMAE_AGENT_API, FORMAE_AGENT_USERNAME/PASSWORD
#      (.github/actions/formae-agent).
set -euo pipefail

STACK="${1:?usage: formae-extract-desired.sh <stack-label> <out.pkl>}"
OUTFILE="${2:?usage: formae-extract-desired.sh <stack-label> <out.pkl>}"
: "${FORMAE_CONFIG:?}" "${FORMAE_AGENT_API:?}" "${FORMAE_AGENT_USERNAME:?}" "${FORMAE_AGENT_PASSWORD:?}"

tmp=$(mktemp -d "${RUNNER_TEMP:-/tmp}/extract-desired.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
api() { curl -fsS -u "$FORMAE_AGENT_USERNAME:$FORMAE_AGENT_PASSWORD" "$FORMAE_AGENT_API/$1"; }

formae extract --desired --output-schema json --yes --config "$FORMAE_CONFIG" \
  --query "stack:${STACK}" "$tmp/forma.json" > /dev/null
api plugins > "$tmp/plugins.json"

# KSUID -> {label, stack, type} for every resource a $ref points at.
echo '{}' > "$tmp/refs.json"
if jq -e '[.. | objects | select(has("$ref"))] | length > 0' "$tmp/forma.json" > /dev/null; then
  formae inventory resources --config "$FORMAE_CONFIG" --max-results 0 \
    --output-consumer machine --output-schema json \
    | jq '[.. | objects | select(has("Ksuid") and has("Type") and has("Label"))
           | {key: .Ksuid, value: {label: .Label, stack: .Stack, type: .Type}}] | from_entries' \
    > "$tmp/refs.json"
fi

jq --slurpfile plugins "$tmp/plugins.json" --slurpfile refs "$tmp/refs.json" '
  # (1) keep only properties the schema declares. A declared path with
  # declared children is pruned recursively; one without children (scalar,
  # Mapping, Listing of scalars) is kept whole. Arrays: per element.
  def prune($fields; $p):
    if type == "object" and ($fields | any(startswith($p + "."))) then
      with_entries(($p + "." + .key) as $k
        | select($fields | index([$k]) != null)
        | .value |= prune($fields; $k))
    elif type == "array" then map(prune($fields; $p))
    else . end;
  def pruneTop($fields):
    with_entries(.key as $k | select($fields | index([$k]) != null) | .value |= prune($fields; $k));
  # (3) $ref formae://<ksuid>#/<property> -> Resolvable object
  def resolveRef:
    if type == "object" and has("$ref") then
      (."$ref" | capture("^formae://(?<id>[^#]+)#/(?<prop>.+)$")) as $m
      | ($refs[0][$m.id] // error("reference to unknown resource \($m.id)")) as $r
      | {"$res": true, "$label": $r.label, "$stack": $r.stack, "$type": $r.type,
         "$property": $m.prop, "$visibility": "Clear"}
    else . end;
  # (2) Resolvable object -> placeholder string, rendered as Pkl below
  def placeholder:
    if type == "object" and ."$res" == true then "__FORMAE_RES__" + (tojson | @base64) + "__" else . end;
  {Forma: (.Resources |= map(.Schema.Fields as $f | .Properties |= pruneTop($f))
           | walk(resolveRef) | walk(placeholder)),
   Plugins: $plugins[0].plugins}
' "$tmp/forma.json" > "$tmp/bundle.json"

formae extract --from-json "$tmp/bundle.json" --yes "$tmp/out/main.pkl" > /dev/null

# (2) placeholders -> `new formae.Resolvable {...}`; (4) backtick identifiers with "/".
perl -MMIME::Base64 -MJSON::PP -pe '
  s{"__FORMAE_RES__([A-Za-z0-9+/=]+)__"}{
    my $r = decode_json(decode_base64($1));
    my @f = ("label = \"$r->{q{$label}}\"", "type = \"$r->{q{$type}}\"");
    push @f, "stack = \"$r->{q{$stack}}\"" if defined $r->{q{$stack}};
    push @f, "property = \"$r->{q{$property}}\"" if defined $r->{q{$property}};
    push @f, "visibility = \"$r->{q{$visibility}}\"" if ($r->{q{$visibility}} // "Clear") ne "Clear";
    "new formae.Resolvable { " . join("; ", @f) . " }"
  }ge;
  s/^(\s*local )([^\s`=]*\/[^\s`=]*)( = )/$1`$2`$3/;
  s/^(\s*)([^\s`]*\/[^\s`]*)$/$1`$2`/;
' "$tmp/out/main.pkl" > "$OUTFILE"

if grep -q 'Unresolved desired reference\|__FORMAE_RES__' "$OUTFILE"; then
  echo "formae-extract-desired.sh: unresolved reference left in $OUTFILE" >&2
  exit 1
fi
