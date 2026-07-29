#!/usr/bin/env bash
set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TLS_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/cfm-autotls-negative.XXXXXX)"
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
cm01.example.test,cm01.example.test,cm01.example.test;cm-vip.example.test,10.10.0.10
nifi01.example.test,nifi01.example.test,nifi01.example.test,10.10.0.11
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
export AUTO_TLS_ORG='Negative Test'
export AUTO_TLS_ORG_UNIT='Data Platform'
export AUTO_TLS_ENCRYPT_HOST_KEYS='true'
export AUTO_TLS_HOST_KEY_PASSWORD='HostKeyPassword12345'
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
for script in 00_prepare_dirs.sh 01_generate_keys_csrs.sh 02_package_customer_csrs.sh 03_create_test_ca.sh 04_sign_csrs_with_test_ca.sh 05_validate_issued_certificates.sh; do
  bash "${script}" >"${TEST_ROOT}/${script}.log" 2>&1
 done

expect_fail() {
  local name="$1"
  shift
  if "$@" >"${TEST_ROOT}/${name}.log" 2>&1; then
    echo "[ERROR] ${name} unexpectedly succeeded"
    cat "${TEST_ROOT}/${name}.log"
    exit 1
  fi
  echo "[PASS] ${name} was rejected as expected"
}

ISSUED="${TEST_ROOT}/AutoTLS/artifacts/issued"
REQUESTS="${TEST_ROOT}/AutoTLS/artifacts/requests"
TEST_CA="${TEST_ROOT}/AutoTLS/artifacts/test-ca"
PASSWORDS="${TEST_ROOT}/AutoTLS/artifacts/passwords"

# Returned certificate does not match its original private key and CSR.
cp "${ISSUED}/nifi01.example.test-cert.pem" "${TEST_ROOT}/nifi-good.pem"
cp "${ISSUED}/cm01.example.test-cert.pem" "${ISSUED}/nifi01.example.test-cert.pem"
expect_fail mismatched_certificate bash 05_validate_issued_certificates.sh
mv "${TEST_ROOT}/nifi-good.pem" "${ISSUED}/nifi01.example.test-cert.pem"

# Correct CSR/key but a required IP SAN is omitted.
cat > "${TEST_ROOT}/missing-san.ext" <<'EXT'
basicConstraints = critical,CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = DNS:nifi01.example.test
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth
EXT
"${OPENSSL_PATH}" x509 -req \
  -in "${REQUESTS}/nifi01.example.test-csr.pem" \
  -CA "${TEST_CA}/test-ca-cert.pem" \
  -CAkey "${TEST_CA}/test-ca-key.pem" \
  -passin "file:${PASSWORDS}/test-ca-key.pass" \
  -CAserial "${TEST_CA}/test-ca-cert.srl" \
  -out "${ISSUED}/nifi01.example.test-cert.pem" \
  -days 365 -sha256 -extfile "${TEST_ROOT}/missing-san.ext" >/dev/null 2>&1
expect_fail missing_required_san bash 05_validate_issued_certificates.sh

cat > "${TEST_ROOT}/restore.env" <<'OVERRIDE'
export AUTO_TLS_OVERWRITE_ISSUED_CERTS='true'
OVERRIDE
TLS_ENV_FILE="${TEST_ROOT}/restore.env" bash 04_sign_csrs_with_test_ca.sh >/dev/null 2>&1
bash 05_validate_issued_certificates.sh >/dev/null 2>&1

# Wrong configured host-key password.
cat > "${TEST_ROOT}/wrong-password.env" <<'OVERRIDE'
export AUTO_TLS_HOST_KEY_PASSWORD='WrongPassword12345'
OVERRIDE
expect_fail wrong_host_key_password env TLS_ENV_FILE="${TEST_ROOT}/wrong-password.env" bash 05_validate_issued_certificates.sh

# Missing returned host certificate.
mv "${ISSUED}/nifi01.example.test-cert.pem" "${TEST_ROOT}/nifi-missing.pem"
expect_fail missing_issued_certificate bash 05_validate_issued_certificates.sh
mv "${TEST_ROOT}/nifi-missing.pem" "${ISSUED}/nifi01.example.test-cert.pem"

# A test CA cannot be submitted live unless the explicit lab override is set.
cat > "${TEST_ROOT}/live-test-ca.env" <<'OVERRIDE'
export AUTO_TLS_DRY_RUN='false'
export AUTO_TLS_ALLOW_TEST_CA_ENABLE='false'
OVERRIDE
expect_fail live_test_ca_submission env TLS_ENV_FILE="${TEST_ROOT}/live-test-ca.env" bash 09_enable_autotls.sh

echo '[OK] Negative validation tests passed.'
