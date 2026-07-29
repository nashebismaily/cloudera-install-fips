#!/usr/bin/env bash
set -euo pipefail
export JAVA_TOOL_OPTIONS='-Djava.security.egd=file:/dev/urandom'

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TLS_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/cloudera-autotls-inventory.XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

cat > "${TEST_ROOT}/EXPORTS" <<EOF_EXPORTS
export MANAGER_HOST='cm01.example.test'
export AGENT_HOST='nifi01.example.test'
export AUTO_TLS_CM_HOST='cm01.example.test'
export AUTO_TLS_HOSTS_CSV='${TEST_ROOT}/hosts.csv'
export AUTO_TLS_AUTO_CREATE_HOSTS_CSV='true'
export AUTO_TLS_HOST_LIST='cm01.example.test nifi01.example.test nifi02.example.test'
export AUTO_TLS_AUTO_DISCOVER_IP_SANS='false'
export AUTO_TLS_CERT_MODE='customer'
export AUTO_TLS_PREREQ_MODE='offline'
export AUTO_TLS_DRY_RUN='true'
export AUTO_TLS_ENCRYPT_HOST_KEYS='false'
export AUTO_TLS_HOST_KEY_PASSWORD=''
export AUTO_TLS_KEYSTORE_PASSWORD='KeyStorePassword12345'
export AUTO_TLS_TRUSTSTORE_PASSWORD='TrustStorePassword12345'
export AUTO_TLS_LOCATION='${TEST_ROOT}/AutoTLS'
export AUTO_TLS_OWNER='root:root'
export CLOUDERA_SERVICE_USER='nonexistent-test-user'
export SYSTEM_PYTHON_BIN='$(command -v python3)'
EOF_EXPORTS

export AUTO_TLS_EXPORTS_FILE="${TEST_ROOT}/EXPORTS"
cd "${TLS_DIR}"
bash 00_prepare_inventory.sh > "${TEST_ROOT}/inventory.log"

[[ -f "${TEST_ROOT}/hosts.csv" ]]
[[ "$(wc -l < "${TEST_ROOT}/hosts.csv" | tr -d ' ')" -eq 4 ]]
grep -q '^cm01.example.test,cm01.example.test,cm01.example.test,$' "${TEST_ROOT}/hosts.csv"
grep -q '^nifi01.example.test,nifi01.example.test,nifi01.example.test,$' "${TEST_ROOT}/hosts.csv"
grep -q '^nifi02.example.test,nifi02.example.test,nifi02.example.test,$' "${TEST_ROOT}/hosts.csv"

# Existing inventory must be preserved rather than regenerated.
sha_before="$(sha256sum "${TEST_ROOT}/hosts.csv" | awk '{print $1}')"
bash 00_prepare_inventory.sh > "${TEST_ROOT}/inventory-second.log"
sha_after="$(sha256sum "${TEST_ROOT}/hosts.csv" | awk '{print $1}')"
[[ "${sha_before}" == "${sha_after}" ]]

echo '[OK] Automatic hosts.csv generation and idempotency test passed.'
