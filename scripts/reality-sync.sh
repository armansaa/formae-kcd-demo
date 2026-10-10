#!/usr/bin/env bash
# reality-sync.sh — serap drift satu stack (realitas menang), lalu tulis desired state ke file.
#
#   scripts/reality-sync.sh <file-stack> <nama-stack>
#   scripts/reality-sync.sh stacks/kcd-demo-app.pkl kcd-demo-app
#
# Alur:
#   1. simulate soft reconcile file stack (mode mesin, JSON)
#   2. tidak ada drift            -> status=clean     (atau code-differs kalau file != agent)
#   3. ada drift, lolos pagar      -> absorb lewat --resolution, tunggu command selesai,
#                                     extract --desired ke file -> status=absorbed
#   4. ada drift, kena pagar       -> tidak menyentuh apa pun -> status=blocked
#
# Pagar (tanpa approval manusia, jadi ini satu-satunya rem):
#   - hanya Operation "update" yang boleh diserap; delete/create => blocked
#   - hanya tipe di ALLOWED_TYPES yang boleh diserap
#   - satu resolusi wajib memutuskan SEMUA resource yang drift, jadi satu saja yang kena
#     pagar membuat seluruh run berhenti (tidak ada absorb sebagian)
#
# Output (ke $GITHUB_OUTPUT kalau ada): status, summary (path markdown), command_id
set -euo pipefail

STACK_FILE="${1:?pakai: reality-sync.sh <file-stack> <nama-stack>}"
STACK="${2:?pakai: reality-sync.sh <file-stack> <nama-stack>}"
PROFILE="${FORMAE_PROFILE:-ci}"
ALLOWED_TYPES="${ALLOWED_TYPES:-K8S::Core::ConfigMap K8S::Apps::Deployment K8S::Batch::CronJob}"
POLL_TIMEOUT="${POLL_TIMEOUT:-300}"

OUT="${RUNNER_TEMP:-/tmp}/reality-sync-${STACK}"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.md"
: > "$SUMMARY"

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
    # Tidak ada drift, tapi file di Git berbeda dari desired state agent. Terjadi kalau PR
    # reality-sync sebelumnya belum di-merge/ditutup, atau ada editan manusia di main.
    # Bot TIDAK menerapkan perubahan kode; itu keputusan manusia.
    {
      echo "### reality-sync: \`$STACK\` — file berbeda dari agent, tanpa drift"
      echo
      echo "Tidak ada perubahan dari luar. File di \`main\` berbeda dari desired state agent"
      echo "(PR reality-sync belum di-merge, atau ada editan kode). Bot tidak menerapkannya."
    } >> "$SUMMARY"
    finish code-differs
  fi
  echo "### reality-sync: \`$STACK\` — bersih, tidak ada drift" >> "$SUMMARY"
  finish clean
fi

if ! jq -e '.data.ObservationID // empty' "$OUT/simulate.json" > /dev/null 2>&1; then
  echo "Simulate gagal dan bukan karena drift:" >&2
  cat "$OUT/simulate.json" "$OUT/simulate.err" >&2 || true
  finish error 1
fi

# ---------- 2. baca drift + pagar ----------
OBS_ID="$(jq -r '.data.ObservationID' "$OUT/simulate.json")"
jq -c '[.data.ModifiedStacks[]?.ModifiedResources[]?]' "$OUT/simulate.json" > "$OUT/resources.json"
count="$(jq 'length' "$OUT/resources.json")"
[[ "$count" -gt 0 ]] || { echo "ObservationID tanpa resource" >&2; finish error 1; }

blocked_reasons="$(jq -r --arg allowed "$ALLOWED_TYPES" '
  ($allowed | split(" ")) as $ok
  | .[] as $r
  | $r
  | if (.Operation | ascii_downcase) != "update" then
      "- `\(.Type)` `\(.Label)`: operasi `\(.Operation)` (bukan update) — penghapusan/pembuatan dari luar tidak pernah diserap otomatis"
    elif ($ok | index($r.Type)) == null then
      "- `\(.Type)` `\(.Label)`: tipe tidak ada di allowlist"
    else empty end' "$OUT/resources.json")"

render_changes() {
  jq -r '.[] |
    "- **`\(.Type)` `\(.Label)`** (\(.Operation))",
    ( (.PatchDocument // [])[]? |
      "  - `\(.op)` `\(.path)`" + (if has("value") then " → `\(.value | tostring)`" else "" end) )' \
    "$OUT/resources.json"
}

if [[ -n "$blocked_reasons" ]]; then
  {
    echo "### reality-sync: \`$STACK\` — drift DIBLOKIR pagar, tidak ada yang diubah"
    echo
    echo "ObservationID: \`$OBS_ID\`"
    echo
    echo "Alasan:"
    echo "$blocked_reasons"
    echo
    echo "Drift yang terlihat:"
    render_changes
    echo
    echo "Putuskan manual: absorb (realitas menang) atau revert (kode menang) dengan"
    echo "\`formae apply --mode reconcile $STACK_FILE\` dari mesin yang terhubung ke agent."
  } >> "$SUMMARY"
  finish blocked
fi

# ---------- 3. absorb lewat --resolution ----------
jq -n --arg obs "$OBS_ID" --slurpfile r "$OUT/resources.json" '{
  ObservationID: $obs,
  IdempotencyKey: ("reality-sync-" + $obs),
  Decisions: [ $r[0][] | {ResourceID: .ResourceID, Action: "absorb"} ]
}' > "$OUT/resolution.json"

formae_m apply --mode reconcile --yes \
  --resolution "$OUT/resolution.json" \
  --message "reality-sync: absorb drift ${STACK} (${GITHUB_RUN_ID:-manual})" \
  "$STACK_FILE" > "$OUT/apply.json"

CMD_ID="$(jq -r '.CommandId // empty' "$OUT/apply.json")"
[[ -n "$CMD_ID" ]] || { echo "Apply tidak mengembalikan CommandId:" >&2; cat "$OUT/apply.json" >&2; finish error 1; }
out command_id "$CMD_ID"

deadline=$(( SECONDS + POLL_TIMEOUT ))
state=""
while (( SECONDS < deadline )); do
  formae_m command status "$CMD_ID" > "$OUT/status.json"
  state="$(jq -r '.Commands[0].State // empty' "$OUT/status.json")"
  case "$state" in
    Success) break ;;
    Failed|Canceled|Cancelled) echo "Command $CMD_ID berakhir: $state" >&2; cat "$OUT/status.json" >&2; finish error 1 ;;
  esac
  sleep 5
done
[[ "$state" == "Success" ]] || { echo "Timeout menunggu $CMD_ID (state=$state)" >&2; finish error 1; }

# ---------- 4. tulis balik desired state ke file ----------
# Kalau extract gagal (mis. field di luar skema plugin, lihat temuan Cloud SQL), run berhenti
# sebagai error: agent sudah menyerap, tapi Git belum. Itu harus dilihat manusia.
formae extract --desired --yes --profile "$PROFILE" --query "stack:${STACK}" "$OUT/extracted.pkl"
cp "$OUT/extracted.pkl" "$STACK_FILE"

{
  echo "## reality-sync: drift diserap di \`$STACK\` (realitas menang)"
  echo
  echo "Perubahan berikut terjadi **di luar formae** (kubectl/console) dan sudah dicatat agent"
  echo "sebagai desired intent. PR ini menyamakan Git dengan kenyataan."
  echo
  render_changes
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| ObservationID | \`$OBS_ID\` |"
  echo "| CommandId formae | \`$CMD_ID\` |"
  echo "| Run | ${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-} |"
  echo
  echo "Tidak setuju? Tutup PR ini, lalu terapkan isi \`main\` secara manual dari mesin yang"
  echo "terhubung ke agent: \`formae apply --mode reconcile $STACK_FILE\`. Karena drift sudah"
  echo "diserap, formae akan menampilkannya sebagai perubahan kode biasa (kode menang)."
} >> "$SUMMARY"
finish absorbed
