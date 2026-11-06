#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 16_generate_cfm_fips_config
validate_platform
require_artifact_lock
ensure_java_default
validate_cm_java
mode="${1:-render}"
[[ "${mode}" == render || "${mode}" == trust ]] || { echo 'Usage: 16_generate_cfm_fips_config.sh [render|trust]'; exit 1; }
prepare_database_truststore require-cluster
if [[ "${mode}" == trust ]]; then
  echo '[OK] Local runtime truststore refreshed with approved public, DB and cluster CAs.'
  exit 0
fi
[[ -n "${NIFI_INITIAL_ADMIN_IDENTITY}" && -n "${REGISTRY_INITIAL_ADMIN_IDENTITY}" ]] || {
  echo '[ERROR] Set both initial admin identities to the actual certificate/identity-provider identities before generating role configuration.'; exit 1;
}
identity_settings="$("${SYSTEM_PYTHON_BIN}" "${SCRIPT_DIR}/lib/node_identity.py")"
eval "${identity_settings}"
[[ ${#NIFI_SENSITIVE_PROPS_KEY} -ge ${MIN_FIPS_PASSWORD_LENGTH} ]] || { echo '[ERROR] Set a FIPS-length NiFi sensitive properties key'; exit 1; }
[[ ${#NIFI_TRUSTSTORE_PASSWORD} -ge ${MIN_FIPS_PASSWORD_LENGTH} ]] || { echo '[ERROR] Set NIFI_TRUSTSTORE_PASSWORD to the actual Auto-TLS truststore password'; exit 1; }
"${SYSTEM_PYTHON_BIN}" "${SCRIPT_DIR}/lib/render_cfm_config.py"
"${SYSTEM_PYTHON_BIN}" "${SCRIPT_DIR}/lib/inspect_csd.py"
echo "[OK] Private configuration files generated: ${CFM_GENERATED_CONFIG_DIR}"
echo '[NEXT] Apply the generated files to the exact CM fields listed in service-settings.json; do not start roles before all fields are applied.'
