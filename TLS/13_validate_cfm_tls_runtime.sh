#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
validate_platform
"${SYSTEM_PYTHON_BIN}" "${TLS_MODULE_DIR}/lib/validate_secure_runtime.py" "${1:-nifi}"
