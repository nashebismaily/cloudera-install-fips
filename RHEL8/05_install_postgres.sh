#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
log_init "05_install_postgres"
need_root
validate_platform

if [[ "${PG_MAJOR}" != "${VALIDATED_PG_MAJOR}" ]]; then
  echo "[WARN] This install profile was validated with PostgreSQL ${VALIDATED_PG_MAJOR}; current PG_MAJOR=${PG_MAJOR}. Confirm the support matrix for CDP Runtime ${CDP_RUNTIME_VERSION}."
fi

echo "==== Installing PostgreSQL ${PG_MAJOR} ===="
read -r -a packages <<< "${PG_PACKAGES}"
dnf install -y "${packages[@]}"

if ! id "${PG_OS_USER}" >/dev/null 2>&1; then
  echo "[ERROR] PostgreSQL OS user was not created: ${PG_OS_USER}"
  exit 1
fi

# Live-install fix: the custom data directory parent must be traversable.
PGDATA_PARENT="$(dirname "${PGDATA_DIR}")"
mkdir -p "${PGDATA_PARENT}" "${PGDATA_DIR}"
chmod "${PGDATA_PARENT_MODE}" "${PGDATA_PARENT}"
chown -R "${PGDATA_OWNER}" "${PGDATA_DIR}"
chmod "${PGDATA_DIR_MODE}" "${PGDATA_DIR}"
restorecon -Rv "${PGDATA_PARENT}" "${PGDATA_DIR}" 2>/dev/null || true

mkdir -p "${PG_SYSTEMD_OVERRIDE_DIR}"
cat >"${PG_SYSTEMD_OVERRIDE_FILE}" <<EOFPGDATA
[Service]
Environment=PGDATA=${PGDATA_DIR}
EOFPGDATA

mkdir -p "${PG_SYSCONFIG_DIR}"
cat >"${PG_SYSCONFIG_FILE}" <<EOFPG
PGDATA=${PGDATA_DIR}
EOFPG

if command -v semanage >/dev/null 2>&1; then
  semanage fcontext -a -t postgresql_db_t "${PGDATA_DIR}(/.*)?" 2>/dev/null || \
    semanage fcontext -m -t postgresql_db_t "${PGDATA_DIR}(/.*)?" || true
  restorecon -Rv "${PGDATA_PARENT}" "${PGDATA_DIR}" || true
else
  echo "[WARN] semanage not found; skipping SELinux fcontext configuration for ${PGDATA_DIR}"
fi

if [[ ! -f "${PGDATA_DIR}/PG_VERSION" ]]; then
  echo "==== Initializing database at ${PGDATA_DIR} ===="
  runuser -u "${PG_OS_USER}" -- "${PG_BIN_DIR}/initdb" -D "${PGDATA_DIR}"
else
  echo "[INFO] Existing PostgreSQL data directory detected at ${PGDATA_DIR}"
fi

chown -R "${PGDATA_OWNER}" "${PGDATA_DIR}"
chmod "${PGDATA_DIR_MODE}" "${PGDATA_DIR}"
systemctl daemon-reload
systemctl enable "${PG_SERVICE_NAME}"
systemctl reset-failed "${PG_SERVICE_NAME}" || true
systemctl restart "${PG_SERVICE_NAME}"
sleep "${POSTGRES_SETTLE_SECONDS}"
systemctl status "${PG_SERVICE_NAME}" --no-pager
runuser -u "${PG_OS_USER}" -- "${PG_BIN_DIR}/psql" -c 'SELECT version();'

echo "[OK] PostgreSQL ${PG_MAJOR} installed and running with PGDATA=${PGDATA_DIR}"
