#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 06_configure_postgres_networking
validate_platform
"${SYSTEM_PYTHON_BIN}" -c 'import ipaddress,os; ipaddress.ip_network(os.environ["ALLOWED_CIDR"],strict=False)'
[[ "${DB_SSLMODE}" == disable ]] || { echo '[ERROR] The standard lab profile uses DB_SSLMODE=disable'; exit 1; }
if [[ "${POSTGRES_INSTALL_MODE}" == external ]]; then
  echo '[INFO] External database: provision the database/user pairs and permit non-SSL SCRAM connections.'
  exit 0
fi
POSTGRESQL_CONF="${PGDATA_DIR}/${POSTGRESQL_CONF_NAME}"
PG_HBA="${PGDATA_DIR}/${PG_HBA_CONF_NAME}"
[[ -f "${POSTGRESQL_CONF}" && -f "${PG_HBA}" ]] || { echo '[ERROR] Initialize PGDATA with step 05 first'; exit 1; }
timestamped_backup "${POSTGRESQL_CONF}"
timestamped_backup "${PG_HBA}"
"${SYSTEM_PYTHON_BIN}" - "${POSTGRESQL_CONF}" <<'PY'
import os,re,sys
from pathlib import Path
p=Path(sys.argv[1]);text=p.read_text()
begin,end='# BEGIN MANAGED RHEL9 PostgreSQL','# END MANAGED RHEL9 PostgreSQL'
text=re.sub(re.escape(begin)+r'.*?'+re.escape(end)+r'\n?','',text,flags=re.S)
values={'listen_addresses':os.environ['POSTGRES_LISTEN_ADDRESSES'],
        'port':os.environ['DB_PORT'],'ssl':'off',
        'password_encryption':os.environ['PG_PASSWORD_ENCRYPTION']}
for key in values:
    text=re.sub(r'^\s*'+re.escape(key)+r'\s*=.*$',lambda m:'# '+m.group(),text,flags=re.M)
for value in values.values():
    if "'" in value or '\n' in value or '\r' in value: raise SystemExit('Unsafe PostgreSQL setting')
block='\n'.join(key+" = '"+value+"'" for key,value in values.items())
p.write_text(text.rstrip()+'\n\n'+begin+'\n'+block+'\n'+end+'\n')
PY
tmp="$(mktemp)"
awk -v begin="${PG_HBA_MANAGED_BEGIN}" -v end="${PG_HBA_MANAGED_END}" '$0==begin{skip=1;next} $0==end{skip=0;next} !skip{print}' "${PG_HBA}" > "${tmp}"
cat > "${PG_HBA}" <<EOFHBA
${PG_HBA_MANAGED_BEGIN}
host all all ${PG_HBA_LOOPBACK_IPV4} ${PG_HBA_AUTH_METHOD}
host all all ${PG_HBA_LOOPBACK_IPV6} ${PG_HBA_AUTH_METHOD}
host all all ${ALLOWED_CIDR} ${PG_HBA_AUTH_METHOD}
host all all ${PG_HBA_REJECT_IPV4} reject
host all all ${PG_HBA_REJECT_IPV6} reject
${PG_HBA_MANAGED_END}
EOFHBA
cat "${tmp}" >> "${PG_HBA}"
rm -f -- "${tmp}"
chown "${PGDATA_OWNER}" "${POSTGRESQL_CONF}" "${PG_HBA}"
systemctl restart "${PG_SERVICE_NAME}"
runuser -u "${PG_OS_USER}" -- "${PG_BIN_DIR}/psql" -p "${DB_PORT}" -v ON_ERROR_STOP=1 -c 'SHOW ssl; SHOW password_encryption;'
echo '[OK] PostgreSQL accepts non-SSL SCRAM connections on the configured interfaces/CIDR.'
