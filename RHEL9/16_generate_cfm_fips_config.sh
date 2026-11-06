#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 16_generate_cfm_fips_config
validate_platform
require_artifact_lock
[[ ${#NIFI_SENSITIVE_PROPS_KEY} -ge ${MIN_FIPS_PASSWORD_LENGTH} ]] || { echo '[ERROR] Set a FIPS-length NiFi sensitive properties key'; exit 1; }
"${SYSTEM_PYTHON_BIN}" "${SCRIPT_DIR}/lib/render_cfm_config.py"
"${SYSTEM_PYTHON_BIN}" "${SCRIPT_DIR}/lib/inspect_csd.py"
echo "[OK] HTTP/FIPS configuration files generated: ${CFM_GENERATED_CONFIG_DIR}"
echo '[NEXT] Apply the generated settings to every role configuration group before starting NiFi/Registry.'
