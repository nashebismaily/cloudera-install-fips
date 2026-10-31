#!/usr/bin/env bash
set -euo pipefail
export JAVA_TOOL_OPTIONS='-Djava.security.egd=file:/dev/urandom'

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TLS_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/cfm-autotls-offline.XXXXXX)"
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
export AUTO_TLS_ORG='Offline Test'
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

run_step() {
  local script="$1"
  echo "[TEST] ${script}"
  bash "${script}" >"${TEST_ROOT}/${script}.log" 2>&1 || {
    cat "${TEST_ROOT}/${script}.log"
    return 1
  }
}

for script in \
  00_prepare_dirs.sh \
  01_generate_keys_csrs.sh \
  02_package_customer_csrs.sh \
  03_create_test_ca.sh \
  04_sign_csrs_with_test_ca.sh \
  05_validate_issued_certificates.sh \
  06_build_pkcs12_stores.sh \
  07_validate_artifacts.sh \
  08_validate_autotls_prereqs.sh \
  09_enable_autotls.sh; do
  run_step "${script}"
done

# Verify idempotent reruns preserve existing key/CSR/test-CA material.
KEY_BEFORE="$(sha256sum "${TEST_ROOT}/AutoTLS/artifacts/private/cm01.example.test-key.pem")"
CSR_BEFORE="$(sha256sum "${TEST_ROOT}/AutoTLS/artifacts/requests/cm01.example.test-csr.pem")"
CA_BEFORE="$(sha256sum "${TEST_ROOT}/AutoTLS/artifacts/test-ca/test-ca-cert.pem")"
run_step 01_generate_keys_csrs.sh
run_step 03_create_test_ca.sh
run_step 04_sign_csrs_with_test_ca.sh
[[ "${KEY_BEFORE}" == "$(sha256sum "${TEST_ROOT}/AutoTLS/artifacts/private/cm01.example.test-key.pem")" ]]
[[ "${CSR_BEFORE}" == "$(sha256sum "${TEST_ROOT}/AutoTLS/artifacts/requests/cm01.example.test-csr.pem")" ]]
[[ "${CA_BEFORE}" == "$(sha256sum "${TEST_ROOT}/AutoTLS/artifacts/test-ca/test-ca-cert.pem")" ]]

"${PYTHON_PATH}" - "${TEST_ROOT}" <<'PY'
import json
import tarfile
import sys
from pathlib import Path

root = Path(sys.argv[1])
artifacts = root / "AutoTLS" / "artifacts"
package = artifacts / "requests" / "customer-csr-package.tar.gz"
with tarfile.open(package, "r:gz") as tf:
    names = tf.getnames()
assert sum(name.endswith("-csr.pem") for name in names) == 2, names
assert not any(
    "key.pem" in name.lower()
    or "password" in name.lower()
    or name.lower().endswith(".pass")
    or "/private/" in name.lower()
    for name in names
), names

payload = json.loads((artifacts / "payload" / "generate-cmca-payload.json").read_text())
assert len(payload["hostCerts"]) == 2
assert payload["cmHostCert"].endswith("cm01.example.test-cert.pem")
assert payload["caCert"].endswith("issued/ca-chain.pem")
assert (root / "AutoTLS" / "hosts-key-store" / "cm01.example.test" / "cm-auto-host_key.pw").is_file()
assert (root / "AutoTLS" / "hosts-key-store" / "nifi01.example.test" / "cm-auto-host_key.pw").is_file()
print("[PASS] Package, payload, multi-host, password-file, and idempotency assertions passed")
PY

echo '[OK] Offline two-host customer-style Auto-TLS workflow test passed.'
