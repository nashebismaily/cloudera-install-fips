#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

[[ "${AUTO_TLS_CERT_MODE}" == "test" ]] || fail "03_create_test_ca.sh is only allowed when AUTO_TLS_CERT_MODE=test"
require_var AUTO_TLS_TEST_CA_KEY_PASSWORD
validate_password AUTO_TLS_TEST_CA_KEY_PASSWORD
require_cmd "${OPENSSL_BIN}"
prepare_dirs

if [[ -f "${AUTO_TLS_TEST_CA_KEY_FILE}" || -f "${AUTO_TLS_TEST_CA_CERT_FILE}" ]]; then
  if [[ "${AUTO_TLS_OVERWRITE_TEST_CA}" != "true" ]]; then
    [[ -f "${AUTO_TLS_TEST_CA_KEY_FILE}" && -f "${AUTO_TLS_TEST_CA_CERT_FILE}" ]] \
      || fail "Incomplete test CA exists. Set AUTO_TLS_OVERWRITE_TEST_CA=true to replace it."
    "${OPENSSL_BIN}" pkey -in "${AUTO_TLS_TEST_CA_KEY_FILE}" \
      -passin "file:${AUTO_TLS_TEST_CA_KEY_PASSWORD_FILE}" -check -noout
    "${OPENSSL_BIN}" verify -CAfile "${AUTO_TLS_TEST_CA_CERT_FILE}" "${AUTO_TLS_TEST_CA_CERT_FILE}"
    echo "[PASS] Reusing existing valid test CA: ${AUTO_TLS_TEST_CA_CERT_FILE}"
    exit 0
  fi
  echo "[WARN] Replacing existing test CA because AUTO_TLS_OVERWRITE_TEST_CA=true"
fi

cat > "${AUTO_TLS_TEST_CA_OPENSSL_CONFIG}" <<EOF_CNF
[ req ]
prompt = no
default_md = ${AUTO_TLS_DIGEST}
distinguished_name = dn
x509_extensions = v3_ca

[ dn ]
CN = ${AUTO_TLS_TEST_CA_CN}
O = ${AUTO_TLS_ORG}
OU = Test PKI Only
C = ${AUTO_TLS_COUNTRY}
ST = ${AUTO_TLS_STATE}
L = ${AUTO_TLS_LOCALITY}

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = ${AUTO_TLS_TEST_CA_BASIC_CONSTRAINTS}
keyUsage = ${AUTO_TLS_TEST_CA_KEY_USAGE}
EOF_CNF
chmod "${AUTO_TLS_FILE_MODE}" "${AUTO_TLS_TEST_CA_OPENSSL_CONFIG}"

rm -f "${AUTO_TLS_TEST_CA_KEY_FILE}" "${AUTO_TLS_TEST_CA_CERT_FILE}" "${AUTO_TLS_TEST_CA_SERIAL_FILE}"

"${OPENSSL_BIN}" genpkey \
  -algorithm "${AUTO_TLS_KEY_ALGORITHM}" \
  -pkeyopt "${AUTO_TLS_KEYGEN_PKEYOPT}" \
  "-${AUTO_TLS_PRIVATE_KEY_CIPHER}" \
  -pass "file:${AUTO_TLS_TEST_CA_KEY_PASSWORD_FILE}" \
  -out "${AUTO_TLS_TEST_CA_KEY_FILE}"
chmod "${AUTO_TLS_PRIVATE_FILE_MODE}" "${AUTO_TLS_TEST_CA_KEY_FILE}"

"${OPENSSL_BIN}" pkey \
  -in "${AUTO_TLS_TEST_CA_KEY_FILE}" \
  -passin "file:${AUTO_TLS_TEST_CA_KEY_PASSWORD_FILE}" \
  -check -noout

"${OPENSSL_BIN}" req -x509 -new \
  -key "${AUTO_TLS_TEST_CA_KEY_FILE}" \
  -passin "file:${AUTO_TLS_TEST_CA_KEY_PASSWORD_FILE}" \
  -days "${AUTO_TLS_TEST_CA_DAYS}" \
  -out "${AUTO_TLS_TEST_CA_CERT_FILE}" \
  -config "${AUTO_TLS_TEST_CA_OPENSSL_CONFIG}"
chmod "${AUTO_TLS_PUBLIC_FILE_MODE}" "${AUTO_TLS_TEST_CA_CERT_FILE}"

"${OPENSSL_BIN}" x509 -in "${AUTO_TLS_TEST_CA_CERT_FILE}" -noout -subject -issuer -dates
"${OPENSSL_BIN}" verify -CAfile "${AUTO_TLS_TEST_CA_CERT_FILE}" "${AUTO_TLS_TEST_CA_CERT_FILE}"

apply_owner_if_available

echo "[OK] Created isolated test CA: ${AUTO_TLS_TEST_CA_CERT_FILE}"
echo "[WARN] This CA is for workflow testing only and must not be used for a real customer deployment."
