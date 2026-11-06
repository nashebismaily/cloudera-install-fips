#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 07_create_cm_and_registry_dbs
validate_platform
if [[ "${POSTGRES_INSTALL_MODE}" == external ]]; then
  echo '[INFO] Have the DBA provision the database/user pairs from EXPORTS before step 11.'
  exit 0
fi
systemctl is-active --quiet "${PG_SERVICE_NAME}"
create_db_user() {
  local db="$1" user="$2" pass="$3"
  [[ "${db}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ && "${user}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || { echo '[ERROR] Invalid database/user identifier'; return 1; }
  [[ "${pass}" != *$'\n'* && "${pass}" != *$'\r'* ]] || { echo '[ERROR] Database passwords must be single-line values'; return 1; }
  [[ ${#pass} -ge ${MIN_FIPS_PASSWORD_LENGTH} ]] || { echo '[ERROR] Database passwords must be at least the FIPS minimum length'; return 1; }
  runuser -u "${PG_OS_USER}" -- "${PG_BIN_DIR}/psql" -p "${DB_PORT}" -v ON_ERROR_STOP=1 \
    -v db="${db}" -v dbuser="${user}" -v dbpass="${pass}" -v reset_password="${RESET_DB_PASSWORDS}" <<'SQL'
SET password_encryption = 'scram-sha-256';
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'dbuser', :'dbpass')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'dbuser')\gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'dbuser', :'dbpass')
 WHERE :'reset_password' = 'true'\gexec
SELECT format('CREATE DATABASE %I OWNER %I ENCODING ''UTF8''', :'db', :'dbuser')
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db')\gexec
SELECT format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', :'db', :'dbuser')\gexec
SQL
}
create_db_user "${CM_DB_NAME}" "${CM_DB_USER}" "${CM_DB_PASS}"
create_db_user "${RM_DB_NAME}" "${RM_DB_USER}" "${RM_DB_PASS}"
create_db_user "${REG_DB_NAME}" "${REG_DB_USER}" "${REG_DB_PASS}"
if [[ "${CREATE_EXTRA_DBS}" == true ]]; then
  create_db_user "${HUE_DB_NAME}" "${HUE_DB_USER}" "${HUE_DB_PASS}"
  create_db_user "${HIVE_DB_NAME}" "${HIVE_DB_USER}" "${HIVE_DB_PASS}"
  create_db_user "${RANGER_DB_NAME}" "${RANGER_DB_USER}" "${RANGER_DB_PASS}"
fi
echo '[OK] Database roles and databases are ready; existing passwords are preserved unless RESET_DB_PASSWORDS=true.'
