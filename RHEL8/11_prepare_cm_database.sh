#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
log_init "11_prepare_cm_database"
need_root
validate_platform
ensure_java_default
validate_java_11

[[ -x "${CM_PREP_DATABASE_SCRIPT}" ]] || { echo "[ERROR] Missing ${CM_PREP_DATABASE_SCRIPT}. Install the CM server package first."; exit 1; }
systemctl is-active --quiet "${PG_SERVICE_NAME}" || { echo "[ERROR] ${PG_SERVICE_NAME} is not running."; exit 1; }

if command -v nc >/dev/null 2>&1; then
  nc -zv "${DB_HOST}" "${DB_PORT}"
fi

mkdir -p "${POSTGRES_JDBC_DIR}"
if ! compgen -G "${POSTGRES_JDBC_DIR}/${POSTGRES_JDBC_GLOB}" >/dev/null; then
  echo "==== Installing PostgreSQL JDBC driver ===="
  dnf install -y "${POSTGRES_JDBC_PACKAGE}"
  # The JDBC package can change the active Java alternative; restore Java ${JAVA_MAJOR}.
  ensure_java_default
  validate_java_11
fi
if ! compgen -G "${POSTGRES_JDBC_DIR}/${POSTGRES_JDBC_GLOB}" >/dev/null; then
  echo "[ERROR] PostgreSQL JDBC jar not found in ${POSTGRES_JDBC_DIR}."
  exit 1
fi

ensure_java_default
validate_java_11
read -r -a extra_args <<< "${CM_DB_PREP_EXTRA_ARGS}"

echo "==== Running scm_prepare_database.sh ===="
"${CM_PREP_DATABASE_SCRIPT}" "${CM_DB_TYPE}" "${extra_args[@]}" "${CM_DB_NAME}" "${CM_DB_USER}" "${CM_DB_PASS}"

echo "[OK] Cloudera Manager database prepared"
