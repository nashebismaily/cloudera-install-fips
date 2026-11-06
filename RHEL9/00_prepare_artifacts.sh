#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 00_prepare_artifacts
validate_platform
validate_install_inputs "${1:-agent}"
require_cmd "${BOOTSTRAP_PYTHON_BIN}"
# Public Cloudera directories must be traversable before private staging creates
# child directories. Keep downloaded state, credentials and private keys private.
install -d -m 0755 "${CLOUDERA_INSTALL_ROOT}"
"${BOOTSTRAP_PYTHON_BIN}" "${SCRIPT_DIR}/lib/prepare_artifacts.py"
load_artifact_lock
resolve_fips_jars
echo "[OK] Artifact lock: ${ARTIFACT_LOCK_FILE}"
