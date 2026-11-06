#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
log_init "05_install_postgres"
need_root
validate_platform
if [[ "${POSTGRES_INSTALL_MODE}" == external ]]; then
  dnf install -y "postgresql${PG_MAJOR}"
  echo '[INFO] External PostgreSQL selected; provisioning is managed by the DBA.'
  exit 0
fi
[[ "${POSTGRES_INSTALL_MODE}" == local ]] || { echo '[ERROR] POSTGRES_INSTALL_MODE must be local or external'; exit 1; }

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
if [[ ! -d "${PGDATA_PARENT}" ]]; then
  install -d -m "${PGDATA_PARENT_MODE}" "${PGDATA_PARENT}"
fi
chmod "${PGDATA_PARENT_MODE}" "${PGDATA_PARENT}"
runuser -u "${PG_OS_USER}" -- test -x "${PGDATA_PARENT}" || { echo '[ERROR] An ancestor of PGDATA is not traversable by postgres; inspect it with namei -l'; exit 1; }
mkdir -p "${PGDATA_DIR}"
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
  [[ -z "$(find "${PGDATA_DIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]] || { echo '[ERROR] Nonempty PGDATA has no PG_VERSION; inspect it before initializing'; exit 1; }
  runuser -u "${PG_OS_USER}" -- "${PG_BIN_DIR}/initdb" -D "${PGDATA_DIR}" --encoding=UTF8 --locale=C.UTF-8 --auth-local=peer --auth-host=scram-sha-256
else
  [[ "$(cat "${PGDATA_DIR}/PG_VERSION")" == "${PG_MAJOR}" ]] || { echo '[ERROR] PGDATA contains a different PostgreSQL major; use a planned database upgrade.'; exit 1; }
  echo "[INFO] Existing PostgreSQL data directory detected at ${PGDATA_DIR}"
fi

chown -R "${PGDATA_OWNER}" "${PGDATA_DIR}"
chmod "${PGDATA_DIR_MODE}" "${PGDATA_DIR}"
systemctl daemon-reload
systemctl enable "${PG_SERVICE_NAME}"
systemctl reset-failed "${PG_SERVICE_NAME}" || true
echo "[OK] PostgreSQL ${PG_MAJOR} initialized with PGDATA=${PGDATA_DIR}; step 06 configures networking before starting it."
