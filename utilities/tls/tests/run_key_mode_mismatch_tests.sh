#!/usr/bin/env bash
set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TLS_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/cfm-autotls-key-mode-mismatch.XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

OPENSSL_PATH="$(command -v openssl)"
PYTHON_PATH="$(command -v python3)"
KEYTOOL_PATH="$(command -v keytool 2>/dev/null || true)"
[[ -n "${KEYTOOL_PATH}" ]] || { echo '[ERROR] keytool is required'; exit 1; }

run_case() {
  local name="$1" configured_encrypt="$2" actual_encrypt="$3"
  local case_root="${TEST_ROOT}/${name}"
  mkdir -p "${case_root}"
  cat > "${case_root}/hosts.csv" <<'CSV'
host_id,common_name,dns_sans,ip_sans
cm01.example.test,cm01.example.test,cm01.example.test,10.10.2.10
CSV
  cat > "${case_root}/EXPORTS" <<EOF_EXPORTS
export AUTO_TLS_CERT_MODE='test'
export AUTO_TLS_PREREQ_MODE='offline'
export AUTO_TLS_DRY_RUN='true'
export AUTO_TLS_LOCATION='${case_root}/AutoTLS'
export AUTO_TLS_WORKDIR='${case_root}/AutoTLS/artifacts'
export AUTO_TLS_HOSTS_CSV='${case_root}/hosts.csv'
export AUTO_TLS_CM_HOST='cm01.example.test'
export AUTO_TLS_COUNTRY='US'
export AUTO_TLS_STATE='Texas'
export AUTO_TLS_LOCALITY='Houston'
export AUTO_TLS_ORG='Key Mode Test'
export AUTO_TLS_ORG_UNIT='Data Platform'
export AUTO_TLS_ENCRYPT_HOST_KEYS='${configured_encrypt}'
export AUTO_TLS_HOST_KEY_PASSWORD='HostKeyPassword12345'
export AUTO_TLS_KEYSTORE_PASSWORD='KeyStorePassword12345'
export AUTO_TLS_TRUSTSTORE_PASSWORD='TrustStorePassword12345'
export AUTO_TLS_TEST_CA_KEY_PASSWORD='TestCAKeyPassword12345'
export AUTO_TLS_KEY_ALGORITHM='RSA'
export AUTO_TLS_KEY_SIZE='1024'
export AUTO_TLS_MIN_RSA_BITS='1024'
export AUTO_TLS_OWNER='root:root'
export CLOUDERA_SERVICE_USER='cloudera-scm-offline-test-user'
export OPENSSL_BIN='${OPENSSL_PATH}'
export SYSTEM_PYTHON_BIN='${PYTHON_PATH}'
export KEYTOOL_BIN='${KEYTOOL_PATH}'
EOF_EXPORTS
  export AUTO_TLS_EXPORTS_FILE="${case_root}/EXPORTS"
  cd "${TLS_DIR}"
  bash 00_prepare_dirs.sh >/dev/null
  local key="${case_root}/AutoTLS/artifacts/private/cm01.example.test-key.pem"
  local csr="${case_root}/AutoTLS/artifacts/requests/cm01.example.test-csr.pem"
  local cnf="${case_root}/external.cnf"
  cat > "${cnf}" <<'EOF_CNF'
[ req ]
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext
[ dn ]
C = US
ST = Texas
L = Houston
O = Key Mode Test
OU = Data Platform
CN = cm01.example.test
[ req_ext ]
subjectAltName = DNS:cm01.example.test,IP:10.10.2.10
basicConstraints = critical,CA:FALSE
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth
EOF_CNF
  if [[ "${actual_encrypt}" == 'true' ]]; then
    "${OPENSSL_PATH}" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:1024 \
      -aes-256-cbc -pass pass:HostKeyPassword12345 -out "${key}" >/dev/null 2>&1
    "${OPENSSL_PATH}" req -new -key "${key}" -passin pass:HostKeyPassword12345 \
      -out "${csr}" -config "${cnf}" >/dev/null 2>&1
  else
    "${OPENSSL_PATH}" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:1024 \
      -out "${key}" >/dev/null 2>&1
    "${OPENSSL_PATH}" req -new -key "${key}" -out "${csr}" -config "${cnf}" >/dev/null 2>&1
  fi
  chmod 0600 "${key}"
  chmod 0644 "${csr}"

  if bash 01_generate_keys_csrs.sh >"${case_root}/result.log" 2>&1; then
    echo "[ERROR] ${name} unexpectedly succeeded"
    cat "${case_root}/result.log"
    exit 1
  fi
  case "${name}" in
    configured_encrypted_actual_unencrypted)
      grep -q 'is unencrypted, but AUTO_TLS_ENCRYPT_HOST_KEYS=true' "${case_root}/result.log" ;;
    configured_unencrypted_actual_encrypted)
      grep -q 'is encrypted or unreadable, but AUTO_TLS_ENCRYPT_HOST_KEYS=false' "${case_root}/result.log" ;;
  esac
  echo "[PASS] ${name} was rejected with the expected mode error"
}

run_case configured_encrypted_actual_unencrypted true false
run_case configured_unencrypted_actual_encrypted false true

echo '[OK] Host-key mode mismatch tests passed.'
