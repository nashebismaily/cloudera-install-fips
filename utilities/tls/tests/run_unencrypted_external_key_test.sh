#!/usr/bin/env bash
set -euo pipefail
export JAVA_TOOL_OPTIONS='-Djava.security.egd=file:/dev/urandom'

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TLS_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/cfm-autotls-unencrypted-external.XXXXXX)"
KEEP_TEST_ARTIFACTS="${KEEP_TEST_ARTIFACTS:-false}"

cleanup() {
  if [[ "${KEEP_TEST_ARTIFACTS}" == "true" ]]; then
    echo "[INFO] Preserved test artifacts: ${TEST_ROOT}"
  else
    rm -rf "${TEST_ROOT}"
  fi
}
trap cleanup EXIT

OPENSSL_PATH="$(command -v openssl)"
PYTHON_PATH="$(command -v python3)"
KEYTOOL_PATH="$(command -v keytool 2>/dev/null || true)"
[[ -n "${KEYTOOL_PATH}" ]] || { echo '[ERROR] keytool is required'; exit 1; }

cat > "${TEST_ROOT}/hosts.csv" <<'CSV'
host_id,common_name,dns_sans,ip_sans
cm01.example.test,cm01.example.test,cm01.example.test;cm-vip.example.test,10.10.1.10
nifi01.example.test,nifi01.example.test,nifi01.example.test,10.10.1.11
CSV

cat > "${TEST_ROOT}/EXPORTS" <<EOF_EXPORTS
export AUTO_TLS_CERT_MODE='test'
export AUTO_TLS_PREREQ_MODE='offline'
export AUTO_TLS_DRY_RUN='true'
export AUTO_TLS_LOCATION='${TEST_ROOT}/AutoTLS'
export AUTO_TLS_WORKDIR='${TEST_ROOT}/AutoTLS/artifacts'
export AUTO_TLS_HOSTS_CSV='${TEST_ROOT}/hosts.csv'
export AUTO_TLS_CM_HOST='cm01.example.test'
export AUTO_TLS_CM_USER='admin'
export AUTO_TLS_CM_PASSWORD='OfflineTestAdmin123'
export AUTO_TLS_SSH_USER='autotls'
export AUTO_TLS_SSH_KEY_FILE=''
export AUTO_TLS_COUNTRY='US'
export AUTO_TLS_STATE='Texas'
export AUTO_TLS_LOCALITY='Houston'
export AUTO_TLS_ORG='External Customer Test'
export AUTO_TLS_ORG_UNIT='Data Platform'
export AUTO_TLS_ENCRYPT_HOST_KEYS='false'
export AUTO_TLS_HOST_KEY_PASSWORD=''
export AUTO_TLS_KEYSTORE_PASSWORD='KeyStorePassword12345'
export AUTO_TLS_TRUSTSTORE_PASSWORD='TrustStorePassword12345'
export AUTO_TLS_TEST_CA_KEY_PASSWORD='TestCAKeyPassword12345'
export AUTO_TLS_KEY_ALGORITHM='RSA'
export AUTO_TLS_KEY_SIZE='1024'
export AUTO_TLS_MIN_RSA_BITS='1024'
export AUTO_TLS_CERT_DAYS='365'
export AUTO_TLS_MIN_CERT_VALIDITY_DAYS='30'
export AUTO_TLS_OWNER='root:root'
export CLOUDERA_SERVICE_USER='cloudera-scm-offline-test-user'
export OPENSSL_BIN='${OPENSSL_PATH}'
export SYSTEM_PYTHON_BIN='${PYTHON_PATH}'
export KEYTOOL_BIN='${KEYTOOL_PATH}'
EOF_EXPORTS

export AUTO_TLS_EXPORTS_FILE="${TEST_ROOT}/EXPORTS"
cd "${TLS_DIR}"
bash 00_prepare_dirs.sh >/dev/null

PRIVATE_DIR="${TEST_ROOT}/AutoTLS/artifacts/private"
REQUEST_DIR="${TEST_ROOT}/AutoTLS/artifacts/requests"
OPENSSL_DIR="${TEST_ROOT}/external-openssl"
mkdir -p "${OPENSSL_DIR}"

make_external_pair() {
  local host="$1" dns="$2" ip="$3"
  local config="${OPENSSL_DIR}/${host}.cnf"
  cat > "${config}" <<EOF_CNF
[ req ]
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[ dn ]
C = US
ST = Texas
L = Houston
O = External Customer Test
OU = Data Platform
CN = ${host}

[ req_ext ]
subjectAltName = @alt_names
basicConstraints = critical,CA:FALSE
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth

[ alt_names ]
DNS.1 = ${host}
${dns}
IP.1 = ${ip}
EOF_CNF
  "${OPENSSL_PATH}" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:1024 \
    -out "${PRIVATE_DIR}/${host}-key.pem" >/dev/null 2>&1
  "${OPENSSL_PATH}" req -new -key "${PRIVATE_DIR}/${host}-key.pem" \
    -out "${REQUEST_DIR}/${host}-csr.pem" -config "${config}" >/dev/null 2>&1
  chmod 0600 "${PRIVATE_DIR}/${host}-key.pem"
  chmod 0644 "${REQUEST_DIR}/${host}-csr.pem"
}

make_external_pair cm01.example.test 'DNS.2 = cm-vip.example.test' 10.10.1.10
make_external_pair nifi01.example.test '' 10.10.1.11

KEY_BEFORE="$(sha256sum "${PRIVATE_DIR}/cm01.example.test-key.pem")"
CSR_BEFORE="$(sha256sum "${REQUEST_DIR}/cm01.example.test-csr.pem")"

for script in \
  01_generate_keys_csrs.sh \
  02_package_customer_csrs.sh \
  03_create_test_ca.sh \
  04_sign_csrs_with_test_ca.sh \
  05_validate_issued_certificates.sh \
  06_build_pkcs12_stores.sh \
  07_validate_artifacts.sh \
  08_validate_autotls_prereqs.sh \
  09_enable_autotls.sh; do
  echo "[TEST] ${script}"
  bash "${script}" >"${TEST_ROOT}/${script}.log" 2>&1 || {
    cat "${TEST_ROOT}/${script}.log"
    exit 1
  }
done

[[ "${KEY_BEFORE}" == "$(sha256sum "${PRIVATE_DIR}/cm01.example.test-key.pem")" ]]
[[ "${CSR_BEFORE}" == "$(sha256sum "${REQUEST_DIR}/cm01.example.test-csr.pem")" ]]
[[ ! -e "${TEST_ROOT}/AutoTLS/artifacts/passwords/host-key.pass" ]]
find "${TEST_ROOT}/AutoTLS/hosts-key-store" -name cm-auto-host_key.pw -print -quit | grep -q . && {
  echo '[ERROR] Unencrypted mode unexpectedly created a per-host key password file'
  exit 1
}

grep -q 'Reusing existing matching unencrypted/no-password key and CSR' "${TEST_ROOT}/01_generate_keys_csrs.sh.log"
grep -q 'no host-key password files were created' "${TEST_ROOT}/09_enable_autotls.sh.log"

tar -tzf "${REQUEST_DIR}/customer-csr-package.tar.gz" | grep -E 'key\.pem|\.pass$|password' && {
  echo '[ERROR] CSR package contains a sensitive key/password path'
  exit 1
} || true

echo '[OK] Externally generated unencrypted key/CSR workflow passed.'
