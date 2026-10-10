#!/usr/bin/env bash
# Menulis profile formae `ci` untuk runner di dalam GKE: bicara langsung ke Service agent
# (ClusterIP, tanpa port-forward). Kredensial basic auth dari env (GitHub Secrets).
set -euo pipefail
: "${FORMAE_USER:?FORMAE_USER kosong (secret repo)}"
: "${FORMAE_PASSWORD:?FORMAE_PASSWORD kosong (secret repo)}"
AGENT_HOST="${FORMAE_AGENT_HOST:-formae.formae.svc.cluster.local}"
AGENT_PORT="${FORMAE_AGENT_PORT:-49684}"

dir="$HOME/.config/formae/profiles"
mkdir -p "$dir"
cat > "$dir/ci.pkl" <<PKL
amends "formae:/Config.pkl"
import "plugins:/AuthBasic.pkl" as AuthBasic

cli {
  connection = new Classic {
    url = "http://${AGENT_HOST}"
    port = ${AGENT_PORT}
    auth = new AuthBasic.CliConfig {
      username = read("env:FORMAE_USER")
      password = read("env:FORMAE_PASSWORD")
    }
  }
}
PKL
chmod 600 "$dir/ci.pkl"
formae --version
formae agent status --profile ci
