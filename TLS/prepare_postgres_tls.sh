#!/usr/bin/env bash
# PostgreSQL uses its own server key, not a copied CM node private key.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
validate_platform
[[ "${DB_HOST}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo '[ERROR] Set DB_HOST to the certificate DNS hostname'; exit 1; }
case "${1:-}" in
  request)
    install -d -m 0755 "${POSTGRES_TLS_SOURCE_DIR}"
    umask 077
    if [[ ! -e "${POSTGRES_TLS_SOURCE_KEY}" ]]; then
      openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:${AUTO_TLS_KEY_SIZE}" -out "${POSTGRES_TLS_SOURCE_KEY}"
    fi
    openssl pkey -in "${POSTGRES_TLS_SOURCE_KEY}" -passin pass: -check -noout
    openssl req -new -sha256 -key "${POSTGRES_TLS_SOURCE_KEY}" -subj "/CN=${DB_HOST}" \
      -addext "subjectAltName=DNS:${DB_HOST}" -addext 'extendedKeyUsage=serverAuth' \
      -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
      -out "${POSTGRES_TLS_SOURCE_DIR}/server.csr"
    chmod 0600 "${POSTGRES_TLS_SOURCE_KEY}"
    echo "[OK] Send ONLY ${POSTGRES_TLS_SOURCE_DIR}/server.csr to the CA."
    echo "Return leaf + intermediate server chain as ${POSTGRES_TLS_SOURCE_CERT}; return CA chain as ${POSTGRES_TLS_SOURCE_CA}."
    ;;
  validate)
    openssl verify -CAfile "${POSTGRES_TLS_SOURCE_CA}" -verify_hostname "${DB_HOST}" -purpose sslserver "${POSTGRES_TLS_SOURCE_CERT}"
    cert_public="$(openssl x509 -in "${POSTGRES_TLS_SOURCE_CERT}" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)"
    key_public="$(openssl pkey -in "${POSTGRES_TLS_SOURCE_KEY}" -passin pass: -pubout -outform DER | sha256sum)"
    [[ "${cert_public}" == "${key_public}" ]] || { echo '[ERROR] PostgreSQL key/certificate mismatch'; exit 1; }
    chmod 0644 "${POSTGRES_TLS_SOURCE_CA}" "${POSTGRES_TLS_SOURCE_CERT}"
    chmod 0600 "${POSTGRES_TLS_SOURCE_KEY}"
    echo "[OK] PostgreSQL TLS inputs verified. Distribute ONLY the public CA chain to database clients: ${DB_CLIENT_CA_FILE}"
    ;;
  *) echo 'Usage: prepare_postgres_tls.sh [request|validate]'; exit 1 ;;
esac
