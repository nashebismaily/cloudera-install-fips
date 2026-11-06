#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 12_generate_cfm_tls_config
validate_platform
prepare_database_truststore require-cluster
if [[ "${1:-render}" == trust ]]; then echo '[OK] Local optional TLS truststore prepared.';exit 0;fi
[[ -n "${NIFI_INITIAL_ADMIN_IDENTITY}" && -n "${REGISTRY_INITIAL_ADMIN_IDENTITY}" ]] || fail 'Set actual initial administrator identities in TLS/EXPORTS'
identity_settings="$("${SYSTEM_PYTHON_BIN}" "${TLS_MODULE_DIR}/lib/node_identity.py")"
eval "${identity_settings}"
"${SYSTEM_PYTHON_BIN}" "${TLS_MODULE_DIR}/lib/render_secure_config.py"
echo "[OK] Optional CFM HTTPS settings: ${CFM_GENERATED_CONFIG_DIR}"
echo '[NEXT] Replace old HTTP safety valves with these TLS settings; keep the existing NiFi sensitive-properties key unchanged.'
