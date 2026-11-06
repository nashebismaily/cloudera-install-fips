#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 17_validate_cfm_runtime
validate_platform
validate_cfm_java
validate_java_fips_providers
"${SYSTEM_PYTHON_BIN}" "${SCRIPT_DIR}/lib/validate_runtime.py" "${1:-nifi}"
