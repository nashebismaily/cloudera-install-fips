#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

ensure_hosts_csv

echo "[INFO] Active Auto-TLS host inventory: ${AUTO_TLS_HOSTS_CSV}"
cat "${AUTO_TLS_HOSTS_CSV}"
