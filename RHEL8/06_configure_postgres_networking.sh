#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
log_init "06_configure_postgres_networking"
need_root
validate_platform

[[ -d "${PGDATA_DIR}" ]] || { echo "[ERROR] PGDATA_DIR not found: ${PGDATA_DIR}"; exit 1; }
POSTGRESQL_CONF="${PGDATA_DIR}/${POSTGRESQL_CONF_NAME}"
PG_HBA="${PGDATA_DIR}/${PG_HBA_CONF_NAME}"
[[ -f "${POSTGRESQL_CONF}" ]] || { echo "[ERROR] Missing ${POSTGRESQL_CONF}"; exit 1; }
[[ -f "${PG_HBA}" ]] || { echo "[ERROR] Missing ${PG_HBA}"; exit 1; }

timestamped_backup "${POSTGRESQL_CONF}"
timestamped_backup "${PG_HBA}"

if grep -q '^[#[:space:]]*listen_addresses' "${POSTGRESQL_CONF}"; then
  sed -i "s/^[#[:space:]]*listen_addresses.*/listen_addresses = '${POSTGRES_LISTEN_ADDRESSES}'/" "${POSTGRESQL_CONF}"
else
  echo "listen_addresses = '${POSTGRES_LISTEN_ADDRESSES}'" >> "${POSTGRESQL_CONF}"
fi

# Put the managed SCRAM rules before any default ident/peer host rules. Appending
# them can leave an earlier ident rule in control and break scm_prepare_database.
tmp="$(mktemp)"
awk -v begin="${PG_HBA_MANAGED_BEGIN}" -v end="${PG_HBA_MANAGED_END}" '
  $0 == begin {skip=1; next}
  $0 == end {skip=0; next}
  skip != 1 {print}
' "${PG_HBA}" > "${tmp}"
cat >"${PG_HBA}" <<EOFHBA
${PG_HBA_MANAGED_BEGIN}
host    all    all    ${PG_HBA_LOOPBACK_IPV4}    ${PG_HBA_AUTH_METHOD}
host    all    all    ${PG_HBA_LOOPBACK_IPV6}    ${PG_HBA_AUTH_METHOD}
host    all    all    ${ALLOWED_CIDR}    ${PG_HBA_AUTH_METHOD}
${PG_HBA_MANAGED_END}
EOFHBA
cat "${tmp}" >> "${PG_HBA}"
rm -f "${tmp}"
chown "${PGDATA_OWNER}" "${POSTGRESQL_CONF}" "${PG_HBA}"

systemctl restart "${PG_SERVICE_NAME}"
sleep "${POSTGRES_SETTLE_SECONDS}"
ss -plnt | grep ":${DB_PORT}" || true
runuser -u "${PG_OS_USER}" -- "${PG_BIN_DIR}/psql" -c 'SHOW listen_addresses;'

echo "[OK] PostgreSQL networking configured for ${ALLOWED_CIDR} using ${PG_HBA_AUTH_METHOD}"
