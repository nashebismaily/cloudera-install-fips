#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 04_install_java_fips_runtime
validate_platform
require_artifact_lock
"${BOOTSTRAP_PYTHON_BIN}" "${SCRIPT_DIR}/lib/install_jdks.py"
"${JAVA_ALTERNATIVES_COMMAND}" --install "${JAVA_ALTERNATIVE_LINK}" java "${JAVA_HOME_TARGET}/bin/java" "${JAVA_ALTERNATIVE_PRIORITY}"
"${JAVA_ALTERNATIVES_COMMAND}" --set java "${JAVA_HOME_TARGET}/bin/java"
"${JAVA_ALTERNATIVES_COMMAND}" --install "${JAVAC_ALTERNATIVE_LINK}" javac "${JAVA_HOME_TARGET}/bin/javac" "${JAVA_ALTERNATIVE_PRIORITY}"
"${JAVA_ALTERNATIVES_COMMAND}" --set javac "${JAVA_HOME_TARGET}/bin/javac"
configure_java_fips_safelogic
prepare_java_public_roots
echo '[OK] CM/CDP and CFM JDKs have the approved FIPS providers.'
