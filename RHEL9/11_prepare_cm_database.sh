#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 11_prepare_cm_database
validate_platform
ensure_java_default
validate_cm_java
[[ -n "${DB_HOST}" ]] || { echo '[ERROR] Set DB_HOST in EXPORTS'; exit 1; }
[[ "${DB_SSLMODE}" == disable ]] || { echo '[ERROR] The standard lab profile uses DB_SSLMODE=disable'; exit 1; }
[[ -x "${CM_PREP_DATABASE_SCRIPT}" ]] || { echo '[ERROR] Install CM server packages before step 11'; exit 1; }
prepare_postgres_jdbc
read -r -a extra_args <<< "${CM_DB_PREP_EXTRA_ARGS}"
for arg in "${extra_args[@]}"; do
  [[ "${arg}" != --ssl && "${arg}" != -s ]] || { echo '[ERROR] Remove SSL-enabling database utility arguments from this lab profile'; exit 1; }
done
# Password travels over stdin; vendor utility output is redacted before logging.
printf '%s\n' "${CM_DB_PASS}" | "${CM_PREP_DATABASE_SCRIPT}" \
  -h "${DB_HOST}" -P "${DB_PORT}" --jdbc-url "${CM_DB_JDBC_URL}" \
  "${extra_args[@]}" "${CM_DB_TYPE}" "${CM_DB_NAME}" "${CM_DB_USER}" 2>&1 | \
  "${SYSTEM_PYTHON_BIN}" "${SCRIPT_DIR}/lib/redact.py"
echo '[OK] CM database configured with SSL disabled.'
