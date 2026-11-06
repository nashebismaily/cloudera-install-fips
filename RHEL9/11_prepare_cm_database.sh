#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 11_prepare_cm_database
validate_platform
ensure_java_default
validate_cm_java
[[ -n "${DB_HOST}" ]] || { echo '[ERROR] Set DB_HOST to the PostgreSQL certificate hostname'; exit 1; }
[[ "${POSTGRES_REQUIRE_TLS}" == true && "${DB_SSLMODE}" == verify-full ]] || { echo '[ERROR] PostgreSQL TLS and hostname verification are required'; exit 1; }
[[ -x "${CM_PREP_DATABASE_SCRIPT}" ]] || { echo '[ERROR] Install CM server packages before step 11'; exit 1; }
prepare_postgres_jdbc
prepare_database_truststore
export JDK_JAVA_OPTIONS="$(fips_java_options) -Djavax.net.ssl.trustStoreType=${JAVA_FIPS_KEYSTORE_TYPE} -Djavax.net.ssl.trustStore=${DB_JAVA_TRUSTSTORE} -Djavax.net.ssl.trustStorePassword=${DB_TRUSTSTORE_PASSWORD}"
# The CM utility can log its arguments, so redact its output before bootstrap logging.
# Password itself is supplied through stdin rather than the command line.
read -r -a extra_args <<< "${CM_DB_PREP_EXTRA_ARGS}"
printf '%s\n' "${CM_DB_PASS}" | "${CM_PREP_DATABASE_SCRIPT}" \
  -h "${DB_HOST}" -P "${DB_PORT}" --jdbc-url "${CM_DB_JDBC_URL}" --ssl \
  "${extra_args[@]}" "${CM_DB_TYPE}" "${CM_DB_NAME}" "${CM_DB_USER}" 2>&1 | \
  "${SYSTEM_PYTHON_BIN}" "${SCRIPT_DIR}/lib/redact.py"
echo '[OK] CM database configured over TLS with full certificate/hostname verification.'
