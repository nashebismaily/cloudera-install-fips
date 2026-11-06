#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 06_configure_postgres_networking
validate_platform
"${SYSTEM_PYTHON_BIN}" -c 'import ipaddress,os; ipaddress.ip_network(os.environ["ALLOWED_CIDR"],strict=False)'
[[ "${POSTGRES_REQUIRE_TLS}" == true ]] || { echo '[ERROR] RHEL9 FIPS requires PostgreSQL TLS'; exit 1; }
[[ -n "${DB_HOST}" && -s "${DB_CLIENT_CA_FILE}" ]] || { echo '[ERROR] Configure DB_HOST and stage DB_CLIENT_CA_FILE'; exit 1; }
if [[ "${POSTGRES_INSTALL_MODE}" == external ]]; then
  echo '[INFO] Verify the externally managed PostgreSQL service requires TLS, SCRAM, and a trusted hostname certificate.'
  exit 0
fi
for file in "${POSTGRES_TLS_SOURCE_CERT}" "${POSTGRES_TLS_SOURCE_KEY}" "${POSTGRES_TLS_SOURCE_CA}"; do
  [[ -s "${file}" ]] || { echo "[ERROR] Missing PostgreSQL TLS material: ${file}"; exit 1; }
done
openssl pkey -in "${POSTGRES_TLS_SOURCE_KEY}" -passin pass: -check -noout
openssl verify -CAfile "${POSTGRES_TLS_SOURCE_CA}" -purpose sslserver \
  -verify_hostname "${DB_HOST}" "${POSTGRES_TLS_SOURCE_CERT}"
cert_public="$(openssl x509 -in "${POSTGRES_TLS_SOURCE_CERT}" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
key_public="$(openssl pkey -in "${POSTGRES_TLS_SOURCE_KEY}" -passin pass: -pubout -outform DER | sha256sum | awk '{print $1}')"
[[ "${cert_public}" == "${key_public}" ]] || { echo '[ERROR] PostgreSQL key and certificate do not match'; exit 1; }
install -d -o "${PG_OS_USER}" -g "${PG_OS_GROUP}" -m 0700 "${POSTGRES_TLS_DIR}"
install -o "${PG_OS_USER}" -g "${PG_OS_GROUP}" -m 0600 "${POSTGRES_TLS_SOURCE_KEY}" "${POSTGRES_TLS_KEY}"
install -o "${PG_OS_USER}" -g "${PG_OS_GROUP}" -m 0644 "${POSTGRES_TLS_SOURCE_CERT}" "${POSTGRES_TLS_CERT}"
install -o "${PG_OS_USER}" -g "${PG_OS_GROUP}" -m 0644 "${POSTGRES_TLS_SOURCE_CA}" "${POSTGRES_TLS_CA}"
POSTGRESQL_CONF="${PGDATA_DIR}/${POSTGRESQL_CONF_NAME}"
PG_HBA="${PGDATA_DIR}/${PG_HBA_CONF_NAME}"
timestamped_backup "${POSTGRESQL_CONF}"
timestamped_backup "${PG_HBA}"
"${SYSTEM_PYTHON_BIN}" - "${POSTGRESQL_CONF}" <<'PY'
import os, re, sys
from pathlib import Path
p=Path(sys.argv[1]);text=p.read_text()
begin,end='# BEGIN MANAGED RHEL9 PostgreSQL','# END MANAGED RHEL9 PostgreSQL'
text=re.sub(re.escape(begin)+r'.*?'+re.escape(end)+r'\n?', '', text, flags=re.S)
values={'listen_addresses':os.environ['POSTGRES_LISTEN_ADDRESSES'],
        'port':os.environ['DB_PORT'], 'ssl':'on',
        'ssl_cert_file':os.environ['POSTGRES_TLS_CERT'], 'ssl_key_file':os.environ['POSTGRES_TLS_KEY'],
        'ssl_ca_file':os.environ['POSTGRES_TLS_CA'], 'ssl_min_protocol_version':os.environ['POSTGRES_TLS_MIN_VERSION'],
        'password_encryption':os.environ['PG_PASSWORD_ENCRYPTION']}
for key in values:
    text=re.sub(r'^\s*'+re.escape(key)+r'\s*=.*$', lambda m:'# '+m.group(),text,flags=re.M)
# Paths are operator configuration; reject characters that can escape SQL config quoting.
for value in values.values():
    if "'" in value or '\n' in value or '\r' in value: raise SystemExit('Unsafe PostgreSQL setting')
block='\n'.join(key+" = '"+value+"'" for key,value in values.items())
p.write_text(text.rstrip()+'\n\n'+begin+'\n'+block+'\n'+end+'\n')
PY
tmp="$(mktemp)"
awk -v begin="${PG_HBA_MANAGED_BEGIN}" -v end="${PG_HBA_MANAGED_END}" '$0==begin{skip=1;next} $0==end{skip=0;next} !skip{print}' "${PG_HBA}" > "${tmp}"
cat > "${PG_HBA}" <<EOF
${PG_HBA_MANAGED_BEGIN}
hostnossl all all ${POSTGRES_REJECT_IPV4} reject
hostnossl all all ${POSTGRES_REJECT_IPV6} reject
hostssl all all ${PG_HBA_LOOPBACK_IPV4} ${PG_HBA_AUTH_METHOD}
hostssl all all ${PG_HBA_LOOPBACK_IPV6} ${PG_HBA_AUTH_METHOD}
hostssl all all ${ALLOWED_CIDR} ${PG_HBA_AUTH_METHOD}
hostssl all all ${POSTGRES_REJECT_IPV4} reject
hostssl all all ${POSTGRES_REJECT_IPV6} reject
${PG_HBA_MANAGED_END}
EOF
cat "${tmp}" >> "${PG_HBA}"
rm -f -- "${tmp}"
chown "${PGDATA_OWNER}" "${POSTGRESQL_CONF}" "${PG_HBA}"
restorecon -Rv "${POSTGRES_TLS_DIR}" 2>/dev/null || true
systemctl restart "${PG_SERVICE_NAME}"
runuser -u "${PG_OS_USER}" -- "${PG_BIN_DIR}/psql" -p "${DB_PORT}" -v ON_ERROR_STOP=1 -c 'SHOW ssl; SHOW password_encryption;'
echo '[OK] PostgreSQL requires TLS for TCP connections and uses SCRAM password authentication.'
