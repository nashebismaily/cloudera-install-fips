#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 04_install_java_fips_runtime
validate_platform
require_artifact_lock
install_jdk_archive "${JAVA_ARCHIVE_FILE}" "${JAVA_ARCHIVE_SHA256}" "${JAVA_HOME_TARGET}"
install_jdk_archive "${CFM_JAVA_ARCHIVE_FILE}" "${CFM_JAVA_ARCHIVE_SHA256}" "${CFM_JAVA_HOME}"
configure_java_fips_safelogic
echo '[OK] CM/CDP and CFM JDKs have the approved FIPS providers.'
