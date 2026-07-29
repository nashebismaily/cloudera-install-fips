#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

prepare_dirs
apply_owner_if_available

echo "[OK] Prepared customer-style Auto-TLS directories under ${AUTO_TLS_WORKDIR}"
find "${AUTO_TLS_WORKDIR}" -maxdepth 2 -type d | sort

echo "[INFO] Host private-key mode: $(host_key_mode_label)"
echo "[INFO] Private keys stay in: ${AUTO_TLS_KEY_DIR}"
echo "[INFO] CSRs sent to the customer are placed in: ${AUTO_TLS_CSR_DIR}"
echo "[INFO] Customer-issued certificates are returned to: ${AUTO_TLS_CERT_DIR}"

# Customer-generated key/CSR pairs can be staged before step 01 using the
# exact <host_id>-key.pem and <host_id>-csr.pem filenames. Step 01 reuses and
# validates them when AUTO_TLS_OVERWRITE_KEYS=false.
