#!/usr/bin/env bash
set -euo pipefail
export JAVA_TOOL_OPTIONS='-Djava.security.egd=file:/dev/urandom'

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TLS_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/cfm-autotls-customer-chain.XXXXXX)"
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
cm01.customer.test,cm01.customer.test,cm01.customer.test;cm-vip.customer.test,10.20.0.10
nifi01.customer.test,nifi01.customer.test,nifi01.customer.test,10.20.0.11
CSV

cat > "${TEST_ROOT}/EXPORTS" <<EOF_EXPORTS
export AUTO_TLS_CERT_MODE='customer'
export AUTO_TLS_PREREQ_MODE='offline'
export AUTO_TLS_DRY_RUN='true'
export AUTO_TLS_LOCATION='${TEST_ROOT}/AutoTLS'
export AUTO_TLS_WORKDIR='${TEST_ROOT}/AutoTLS/artifacts'
export AUTO_TLS_HOSTS_CSV='${TEST_ROOT}/hosts.csv'
export AUTO_TLS_CM_HOST='cm01.customer.test'
export AUTO_TLS_CM_USER='admin'
export AUTO_TLS_CM_PASSWORD='OfflineTestAdmin123'
export AUTO_TLS_SSH_USER='autotls'
export AUTO_TLS_SSH_KEY_FILE=''
export AUTO_TLS_COUNTRY='US'
export AUTO_TLS_STATE='Texas'
export AUTO_TLS_LOCALITY='Houston'
export AUTO_TLS_ORG='Customer Chain Test'
export AUTO_TLS_ORG_UNIT='Data Platform'
export AUTO_TLS_ENCRYPT_HOST_KEYS='true'
export AUTO_TLS_HOST_KEY_PASSWORD='HostKeyPassword12345'
export AUTO_TLS_KEYSTORE_PASSWORD='KeyStorePassword12345'
export AUTO_TLS_TRUSTSTORE_PASSWORD='TrustStorePassword12345'
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
for script in 00_prepare_dirs.sh 01_generate_keys_csrs.sh 02_package_customer_csrs.sh; do
  bash "${script}" >"${TEST_ROOT}/${script}.log" 2>&1
 done

PKI_DIR="${TEST_ROOT}/customer-pki"
mkdir -p "${PKI_DIR}"
"${OPENSSL_PATH}" genrsa -out "${PKI_DIR}/root.key" 2048 >/dev/null 2>&1
"${OPENSSL_PATH}" req -x509 -new -key "${PKI_DIR}/root.key" -sha256 -days 3650 \
  -subj '/C=US/ST=Texas/L=Houston/O=Customer Chain Test/OU=PKI/CN=Customer Root CA' \
  -addext 'basicConstraints=critical,CA:TRUE,pathlen:1' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -out "${PKI_DIR}/root.crt" >/dev/null 2>&1

"${OPENSSL_PATH}" genrsa -out "${PKI_DIR}/intermediate.key" 2048 >/dev/null 2>&1
"${OPENSSL_PATH}" req -new -key "${PKI_DIR}/intermediate.key" \
  -subj '/C=US/ST=Texas/L=Houston/O=Customer Chain Test/OU=PKI/CN=Customer Issuing CA' \
  -out "${PKI_DIR}/intermediate.csr" >/dev/null 2>&1
cat > "${PKI_DIR}/intermediate.ext" <<'EXT'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EXT
"${OPENSSL_PATH}" x509 -req -in "${PKI_DIR}/intermediate.csr" \
  -CA "${PKI_DIR}/root.crt" -CAkey "${PKI_DIR}/root.key" -CAcreateserial \
  -days 1825 -sha256 -extfile "${PKI_DIR}/intermediate.ext" \
  -out "${PKI_DIR}/intermediate.crt" >/dev/null 2>&1

sign_leaf() {
  local host="$1" dns_sans="$2" ip_san="$3"
  cat > "${PKI_DIR}/${host}.ext" <<EOF_EXT
basicConstraints=critical,CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
subjectAltName=${dns_sans},IP:${ip_san}
EOF_EXT
  "${OPENSSL_PATH}" x509 -req \
    -in "${TEST_ROOT}/AutoTLS/artifacts/requests/${host}-csr.pem" \
    -CA "${PKI_DIR}/intermediate.crt" -CAkey "${PKI_DIR}/intermediate.key" \
    -CAserial "${PKI_DIR}/intermediate.srl" -CAcreateserial \
    -days 365 -sha256 -extfile "${PKI_DIR}/${host}.ext" \
    -out "${TEST_ROOT}/AutoTLS/artifacts/issued/${host}-cert.pem" >/dev/null 2>&1
}

sign_leaf cm01.customer.test 'DNS:cm01.customer.test,DNS:cm-vip.customer.test' 10.20.0.10
sign_leaf nifi01.customer.test 'DNS:nifi01.customer.test' 10.20.0.11
cat "${PKI_DIR}/intermediate.crt" "${PKI_DIR}/root.crt" \
  > "${TEST_ROOT}/AutoTLS/artifacts/issued/ca-chain.pem"

for script in \
  05_validate_issued_certificates.sh \
  06_build_pkcs12_stores.sh \
  07_validate_artifacts.sh \
  08_validate_autotls_prereqs.sh \
  09_enable_autotls.sh; do
  bash "${script}" >"${TEST_ROOT}/${script}.log" 2>&1 || {
    cat "${TEST_ROOT}/${script}.log"
    exit 1
  }
 done

"${PYTHON_PATH}" - "${TEST_ROOT}" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
chain = root / "AutoTLS" / "artifacts" / "issued" / "ca-chain.pem"
assert chain.read_text().count("BEGIN CERTIFICATE") == 2
payload = json.loads((root / "AutoTLS" / "artifacts" / "payload" / "generate-cmca-payload.json").read_text())
assert len(payload["hostCerts"]) == 2
assert payload["caCert"].endswith("issued/ca-chain.pem")
print("[PASS] Customer root/intermediate chain and dry-run payload assertions passed")
PY

echo '[OK] Customer-issued two-level CA chain workflow test passed.'
