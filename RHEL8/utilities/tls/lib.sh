#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP_LEVEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOP_LEVEL_EXPORTS="${AUTO_TLS_EXPORTS_FILE:-${TOP_LEVEL_DIR}/EXPORTS}"

[[ -f "${TOP_LEVEL_EXPORTS}" ]] || {
  echo "[ERROR] Missing Auto-TLS configuration file: ${TOP_LEVEL_EXPORTS}" >&2
  echo "[INFO] Expected repository layout: /root/cloudera-install-fips/utilities/tls" >&2
  echo "[INFO] Set AUTO_TLS_EXPORTS_FILE only for isolated testing." >&2
  exit 1
}
# shellcheck disable=SC1090
source "${TOP_LEVEL_EXPORTS}"

TLS_ENV_FILE="${TLS_ENV_FILE:-${SCRIPT_DIR}/tls.env}"
if [[ -f "${TLS_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${TLS_ENV_FILE}"
fi

SYSTEM_PYTHON_BIN="${SYSTEM_PYTHON_BIN:-python3}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
KEYTOOL="${KEYTOOL_BIN:-${KEYTOOL:-$(command -v keytool 2>/dev/null || true)}}"
AUTO_TLS_SSH_BIN="${AUTO_TLS_SSH_BIN:-ssh}"
AUTO_TLS_SSH_KEYGEN_BIN="${AUTO_TLS_SSH_KEYGEN_BIN:-ssh-keygen}"
AUTO_TLS_BASE64_BIN="${AUTO_TLS_BASE64_BIN:-base64}"
AUTO_TLS_VISUDO_BIN="${AUTO_TLS_VISUDO_BIN:-visudo}"

AUTO_TLS_CERT_MODE="${AUTO_TLS_CERT_MODE:-customer}"
AUTO_TLS_PREREQ_MODE="${AUTO_TLS_PREREQ_MODE:-full}"
[[ "${AUTO_TLS_PREREQ_MODE}" == "online" ]] && AUTO_TLS_PREREQ_MODE="full"
AUTO_TLS_DRY_RUN="${AUTO_TLS_DRY_RUN:-true}"
AUTO_TLS_ALLOW_TEST_CA_ENABLE="${AUTO_TLS_ALLOW_TEST_CA_ENABLE:-false}"
AUTO_TLS_OVERWRITE_KEYS="${AUTO_TLS_OVERWRITE_KEYS:-false}"
AUTO_TLS_OVERWRITE_TEST_CA="${AUTO_TLS_OVERWRITE_TEST_CA:-false}"
AUTO_TLS_OVERWRITE_ISSUED_CERTS="${AUTO_TLS_OVERWRITE_ISSUED_CERTS:-false}"
AUTO_TLS_REQUIRE_CN_MATCH="${AUTO_TLS_REQUIRE_CN_MATCH:-true}"
AUTO_TLS_DISALLOW_WILDCARDS="${AUTO_TLS_DISALLOW_WILDCARDS:-true}"
AUTO_TLS_REQUIRE_SUDO="${AUTO_TLS_REQUIRE_SUDO:-true}"
AUTO_TLS_PATHS_FROM_LOCATION="${AUTO_TLS_PATHS_FROM_LOCATION:-true}"

AUTO_TLS_LOCATION="${AUTO_TLS_LOCATION:-/opt/cloudera/AutoTLS}"
if [[ "${AUTO_TLS_PATHS_FROM_LOCATION}" == "true" ]]; then
  AUTO_TLS_WORKDIR="${AUTO_TLS_LOCATION}/artifacts"
  AUTO_TLS_KEY_DIR="${AUTO_TLS_WORKDIR}/private"
  AUTO_TLS_CSR_DIR="${AUTO_TLS_WORKDIR}/requests"
  AUTO_TLS_CERT_DIR="${AUTO_TLS_WORKDIR}/issued"
  AUTO_TLS_FULLCHAIN_DIR="${AUTO_TLS_WORKDIR}/fullchains"
  AUTO_TLS_STORE_DIR="${AUTO_TLS_WORKDIR}/stores"
  AUTO_TLS_PAYLOAD_DIR="${AUTO_TLS_WORKDIR}/payload"
  AUTO_TLS_OPENSSL_DIR="${AUTO_TLS_WORKDIR}/openssl"
  AUTO_TLS_PASSWORD_DIR="${AUTO_TLS_WORKDIR}/passwords"
  AUTO_TLS_TEST_CA_DIR="${AUTO_TLS_WORKDIR}/test-ca"
  AUTO_TLS_HOSTS_KEY_STORE_DIR="${AUTO_TLS_LOCATION}/hosts-key-store"
else
  AUTO_TLS_WORKDIR="${AUTO_TLS_WORKDIR:-${AUTO_TLS_LOCATION}/artifacts}"
  AUTO_TLS_KEY_DIR="${AUTO_TLS_KEY_DIR:-${AUTO_TLS_WORKDIR}/private}"
  AUTO_TLS_CSR_DIR="${AUTO_TLS_CSR_DIR:-${AUTO_TLS_WORKDIR}/requests}"
  AUTO_TLS_CERT_DIR="${AUTO_TLS_CERT_DIR:-${AUTO_TLS_WORKDIR}/issued}"
  AUTO_TLS_FULLCHAIN_DIR="${AUTO_TLS_FULLCHAIN_DIR:-${AUTO_TLS_WORKDIR}/fullchains}"
  AUTO_TLS_STORE_DIR="${AUTO_TLS_STORE_DIR:-${AUTO_TLS_WORKDIR}/stores}"
  AUTO_TLS_PAYLOAD_DIR="${AUTO_TLS_PAYLOAD_DIR:-${AUTO_TLS_WORKDIR}/payload}"
  AUTO_TLS_OPENSSL_DIR="${AUTO_TLS_OPENSSL_DIR:-${AUTO_TLS_WORKDIR}/openssl}"
  AUTO_TLS_PASSWORD_DIR="${AUTO_TLS_PASSWORD_DIR:-${AUTO_TLS_WORKDIR}/passwords}"
  AUTO_TLS_TEST_CA_DIR="${AUTO_TLS_TEST_CA_DIR:-${AUTO_TLS_WORKDIR}/test-ca}"
  AUTO_TLS_HOSTS_KEY_STORE_DIR="${AUTO_TLS_HOSTS_KEY_STORE_DIR:-${AUTO_TLS_LOCATION}/hosts-key-store}"
fi

AUTO_TLS_HOSTS_CSV="${AUTO_TLS_HOSTS_CSV:-${SCRIPT_DIR}/hosts.csv}"
AUTO_TLS_AUTO_CREATE_HOSTS_CSV="${AUTO_TLS_AUTO_CREATE_HOSTS_CSV:-true}"
AUTO_TLS_HOST_LIST="${AUTO_TLS_HOST_LIST:-${AUTO_TLS_CM_HOST:-} ${AGENT_HOST:-}}"
AUTO_TLS_AUTO_DISCOVER_IP_SANS="${AUTO_TLS_AUTO_DISCOVER_IP_SANS:-true}"
AUTO_TLS_CSR_MANIFEST_FILE="${AUTO_TLS_CSR_DIR}/certificate-request-manifest.csv"
AUTO_TLS_CSR_INSTRUCTIONS_FILE="${AUTO_TLS_CSR_DIR}/README-CERTIFICATE-REQUEST.txt"
AUTO_TLS_CSR_CHECKSUM_FILE="${AUTO_TLS_CSR_DIR}/SHA256SUMS"
AUTO_TLS_CSR_PACKAGE_FILE="${AUTO_TLS_CSR_DIR}/customer-csr-package.tar.gz"
AUTO_TLS_ISSUED_CA_CHAIN_FILE="${AUTO_TLS_CERT_DIR}/ca-chain.pem"

AUTO_TLS_TEST_CA_KEY_FILE="${AUTO_TLS_TEST_CA_DIR}/test-ca-key.pem"
AUTO_TLS_TEST_CA_CERT_FILE="${AUTO_TLS_TEST_CA_DIR}/test-ca-cert.pem"
AUTO_TLS_TEST_CA_SERIAL_FILE="${AUTO_TLS_TEST_CA_DIR}/test-ca-cert.srl"
AUTO_TLS_TEST_CA_OPENSSL_CONFIG="${AUTO_TLS_OPENSSL_DIR}/test-ca-openssl.cnf"

AUTO_TLS_HOST_KEY_PASSWORD_FILE="${AUTO_TLS_PASSWORD_DIR}/host-key.pass"
AUTO_TLS_KEYSTORE_PASSWORD_FILE="${AUTO_TLS_PASSWORD_DIR}/keystore.pass"
AUTO_TLS_TRUSTSTORE_PASSWORD_FILE="${AUTO_TLS_PASSWORD_DIR}/truststore.pass"
AUTO_TLS_TEST_CA_KEY_PASSWORD_FILE="${AUTO_TLS_PASSWORD_DIR}/test-ca-key.pass"
AUTO_TLS_HOST_KEY_PASSWORD_FILENAME="${AUTO_TLS_HOST_KEY_PASSWORD_FILENAME:-cm-auto-host_key.pw}"

AUTO_TLS_PAYLOAD_FILE="${AUTO_TLS_PAYLOAD_DIR}/generate-cmca-payload.json"
AUTO_TLS_HTTP_RESPONSE_FILE="${AUTO_TLS_PAYLOAD_DIR}/generate-cmca-response.json"
AUTO_TLS_HOSTS_CHECK_FILE="${AUTO_TLS_PAYLOAD_DIR}/hosts.txt"
AUTO_TLS_CM_VERSION_RESPONSE_FILE="${AUTO_TLS_PAYLOAD_DIR}/cm-version-response.json"
AUTO_TLS_SSH_TEST_OUTPUT_FILE="${AUTO_TLS_PAYLOAD_DIR}/ssh-test.out"
AUTO_TLS_SSH_TEST_ERROR_FILE="${AUTO_TLS_PAYLOAD_DIR}/ssh-test.err"
AUTO_TLS_KEY_CHECK_OUTPUT_FILE="${AUTO_TLS_PAYLOAD_DIR}/key-check.out"
AUTO_TLS_KEY_CHECK_ERROR_FILE="${AUTO_TLS_PAYLOAD_DIR}/key-check.err"
AUTO_TLS_VALIDATION_REPORT_FILE="${AUTO_TLS_PAYLOAD_DIR}/artifact-validation-report.txt"

AUTO_TLS_KEY_ALGORITHM="${AUTO_TLS_KEY_ALGORITHM:-RSA}"
AUTO_TLS_KEY_SIZE="${AUTO_TLS_KEY_SIZE:-3072}"
AUTO_TLS_MIN_RSA_BITS="${AUTO_TLS_MIN_RSA_BITS:-2048}"
AUTO_TLS_KEYGEN_PKEYOPT="${AUTO_TLS_KEYGEN_PKEYOPT:-rsa_keygen_bits:${AUTO_TLS_KEY_SIZE}}"
AUTO_TLS_PRIVATE_KEY_CIPHER="${AUTO_TLS_PRIVATE_KEY_CIPHER:-aes-256-cbc}"
AUTO_TLS_DIGEST="${AUTO_TLS_DIGEST:-sha256}"
AUTO_TLS_KEY_USAGE="${AUTO_TLS_KEY_USAGE:-digitalSignature,keyEncipherment}"
AUTO_TLS_EXTENDED_KEY_USAGE="${AUTO_TLS_EXTENDED_KEY_USAGE:-serverAuth,clientAuth}"
AUTO_TLS_HOST_BASIC_CONSTRAINTS="${AUTO_TLS_HOST_BASIC_CONSTRAINTS:-critical,CA:FALSE}"
AUTO_TLS_TEST_CA_BASIC_CONSTRAINTS="${AUTO_TLS_TEST_CA_BASIC_CONSTRAINTS:-critical,CA:TRUE,pathlen:1}"
AUTO_TLS_TEST_CA_KEY_USAGE="${AUTO_TLS_TEST_CA_KEY_USAGE:-critical,keyCertSign,cRLSign}"
AUTO_TLS_TEST_CA_CN="${AUTO_TLS_TEST_CA_CN:-${AUTO_TLS_CA_CN:-CFM Auto-TLS Test CA}}"
AUTO_TLS_TEST_CA_DAYS="${AUTO_TLS_TEST_CA_DAYS:-${AUTO_TLS_CA_DAYS:-3650}}"
AUTO_TLS_TEST_CA_KEY_PASSWORD="${AUTO_TLS_TEST_CA_KEY_PASSWORD:-${AUTO_TLS_CA_KEY_PASSWORD:-}}"
AUTO_TLS_CERT_DAYS="${AUTO_TLS_CERT_DAYS:-825}"
AUTO_TLS_MIN_CERT_VALIDITY_DAYS="${AUTO_TLS_MIN_CERT_VALIDITY_DAYS:-30}"
AUTO_TLS_STORE_TYPE="${AUTO_TLS_STORE_TYPE:-PKCS12}"
AUTO_TLS_CA_STORE_ALIAS="${AUTO_TLS_CA_STORE_ALIAS:-cloudera-auto-tls-ca}"
AUTO_TLS_ENCRYPT_HOST_KEYS="${AUTO_TLS_ENCRYPT_HOST_KEYS:-true}"
AUTO_TLS_CONFIGURE_ALL_SERVICES="${AUTO_TLS_CONFIGURE_ALL_SERVICES:-true}"

AUTO_TLS_LOCATION_MODE="${AUTO_TLS_LOCATION_MODE:-0750}"
AUTO_TLS_WORKDIR_MODE="${AUTO_TLS_WORKDIR_MODE:-0750}"
AUTO_TLS_PRIVATE_DIR_MODE="${AUTO_TLS_PRIVATE_DIR_MODE:-0700}"
AUTO_TLS_FILE_MODE="${AUTO_TLS_FILE_MODE:-0640}"
AUTO_TLS_PUBLIC_FILE_MODE="${AUTO_TLS_PUBLIC_FILE_MODE:-0644}"
AUTO_TLS_PRIVATE_FILE_MODE="${AUTO_TLS_PRIVATE_FILE_MODE:-0600}"
AUTO_TLS_OWNER="${AUTO_TLS_OWNER:-cloudera-scm:cloudera-scm}"
CLOUDERA_SERVICE_USER="${CLOUDERA_SERVICE_USER:-cloudera-scm}"

# Auto-TLS SSH identity and automatic distribution.
AUTO_TLS_SSH_AUTO_SETUP="${AUTO_TLS_SSH_AUTO_SETUP:-true}"
AUTO_TLS_SSH_USER="${AUTO_TLS_SSH_USER:-autotls}"
AUTO_TLS_SSH_HOME="${AUTO_TLS_SSH_HOME:-/home/${AUTO_TLS_SSH_USER}}"
AUTO_TLS_SSH_PORT="${AUTO_TLS_SSH_PORT:-22}"
if [[ -z "${AUTO_TLS_SSH_KEY_FILE+x}" ]]; then
  AUTO_TLS_SSH_KEY_FILE="${AUTO_TLS_SSH_HOME}/.ssh/id_rsa"
fi
if [[ -z "${AUTO_TLS_SSH_PUBLIC_KEY_FILE+x}" ]]; then
  AUTO_TLS_SSH_PUBLIC_KEY_FILE="${AUTO_TLS_SSH_KEY_FILE}.pub"
fi
AUTO_TLS_SSH_KEY_TYPE="${AUTO_TLS_SSH_KEY_TYPE:-rsa}"
AUTO_TLS_SSH_KEY_BITS="${AUTO_TLS_SSH_KEY_BITS:-4096}"
AUTO_TLS_SSH_KEY_COMMENT="${AUTO_TLS_SSH_KEY_COMMENT:-cloudera-autotls@${AUTO_TLS_CM_HOST:-manager}}"
AUTO_TLS_SSH_SUDOERS_FILE="${AUTO_TLS_SSH_SUDOERS_FILE:-/etc/sudoers.d/${AUTO_TLS_SSH_USER}}"
AUTO_TLS_SSH_PASSWORDLESS_SUDO="${AUTO_TLS_SSH_PASSWORDLESS_SUDO:-true}"
AUTO_TLS_SSH_CONNECT_TIMEOUT_SECONDS="${AUTO_TLS_SSH_CONNECT_TIMEOUT_SECONDS:-10}"
AUTO_TLS_SSH_PASSWORD="${AUTO_TLS_SSH_PASSWORD:-}"

# Existing administrative access used only once to install the dedicated
# Auto-TLS account/public key on remote hosts. The script first tries the
# configured key, then normal SSH identities/agent, then sshpass when a
# bootstrap password is explicitly configured.
AUTO_TLS_BOOTSTRAP_USER="${AUTO_TLS_BOOTSTRAP_USER:-root}"
AUTO_TLS_BOOTSTRAP_PORT="${AUTO_TLS_BOOTSTRAP_PORT:-22}"
AUTO_TLS_BOOTSTRAP_KEY_FILE="${AUTO_TLS_BOOTSTRAP_KEY_FILE:-}"
AUTO_TLS_BOOTSTRAP_PASSWORD="${AUTO_TLS_BOOTSTRAP_PASSWORD:-}"
AUTO_TLS_BOOTSTRAP_USE_DEFAULT_IDENTITIES="${AUTO_TLS_BOOTSTRAP_USE_DEFAULT_IDENTITIES:-true}"
AUTO_TLS_BOOTSTRAP_REQUIRE_SUDO="${AUTO_TLS_BOOTSTRAP_REQUIRE_SUDO:-true}"
AUTO_TLS_SSH_SETUP_SANDBOX_ROOT="${AUTO_TLS_SSH_SETUP_SANDBOX_ROOT:-}"
AUTO_TLS_SSH_SETUP_PLAN_ONLY="${AUTO_TLS_SSH_SETUP_PLAN_ONLY:-false}"

AUTO_TLS_REQUIRED_COMMANDS="${AUTO_TLS_REQUIRED_COMMANDS:-openssl tar sha256sum curl ssh getent}"
AUTO_TLS_CM_SCHEME="${AUTO_TLS_CM_SCHEME:-http}"
AUTO_TLS_CM_PORT="${AUTO_TLS_CM_PORT:-7180}"
AUTO_TLS_CM_HTTPS_PORT="${AUTO_TLS_CM_HTTPS_PORT:-7183}"
AUTO_TLS_CM_API_VERSION="${AUTO_TLS_CM_API_VERSION:-v41}"
AUTO_TLS_CM_VERSION_PATH="${AUTO_TLS_CM_VERSION_PATH:-/cm/version}"
AUTO_TLS_GENERATE_CMCA_PATH="${AUTO_TLS_GENERATE_CMCA_PATH:-/cm/commands/generateCmca}"
AUTO_TLS_COMMAND_STATUS_PATH="${AUTO_TLS_COMMAND_STATUS_PATH:-/commands}"
AUTO_TLS_SUCCESS_HTTP_CODES="${AUTO_TLS_SUCCESS_HTTP_CODES:-200 201 202}"
AUTO_TLS_WAIT_FOR_COMMAND="${AUTO_TLS_WAIT_FOR_COMMAND:-true}"
AUTO_TLS_COMMAND_POLL_SECONDS="${AUTO_TLS_COMMAND_POLL_SECONDS:-10}"
AUTO_TLS_COMMAND_TIMEOUT_SECONDS="${AUTO_TLS_COMMAND_TIMEOUT_SECONDS:-1800}"
AUTO_TLS_REQUIRE_LIVE_CONFIRMATION="${AUTO_TLS_REQUIRE_LIVE_CONFIRMATION:-true}"
AUTO_TLS_CONFIRM_LIVE="${AUTO_TLS_CONFIRM_LIVE:-}"
AUTO_TLS_AUTO_POST_RESTART="${AUTO_TLS_AUTO_POST_RESTART:-false}"
AUTO_TLS_POST_RESTART_MANAGEMENT_SERVICE="${AUTO_TLS_POST_RESTART_MANAGEMENT_SERVICE:-true}"
AUTO_TLS_POST_RESTART_CLUSTERS="${AUTO_TLS_POST_RESTART_CLUSTERS:-true}"
AUTO_TLS_POST_DEPLOY_CLIENT_CONFIG="${AUTO_TLS_POST_DEPLOY_CLIENT_CONFIG:-true}"
AUTO_TLS_HTTPS_WAIT_SECONDS="${AUTO_TLS_HTTPS_WAIT_SECONDS:-600}"
AUTO_TLS_REQUIRE_POST_RESTART_CONFIRMATION="${AUTO_TLS_REQUIRE_POST_RESTART_CONFIRMATION:-true}"
AUTO_TLS_CONFIRM_POST_RESTART="${AUTO_TLS_CONFIRM_POST_RESTART:-}"
CURL_INSECURE="${CURL_INSECURE:-false}"
CM_HTTPS_SCHEME="${CM_HTTPS_SCHEME:-https}"
CM_SERVER_SERVICE="${CM_SERVER_SERVICE:-cloudera-scm-server}"
CM_AGENT_SERVICE="${CM_AGENT_SERVICE:-cloudera-scm-agent}"
AUTO_TLS_SERVER_LOG_FILE="${AUTO_TLS_SERVER_LOG_FILE:-/var/log/cloudera-scm-server/cloudera-scm-server.log}"
AUTO_TLS_CERTMANAGER_LOG_FILE="${AUTO_TLS_CERTMANAGER_LOG_FILE:-/var/log/cloudera-scm-agent/certmanager.log}"

# Backward-compatible aliases.
TLS_WORKDIR="${AUTO_TLS_WORKDIR}"
TLS_HOSTS_FILE="${AUTO_TLS_HOSTS_CSV}"
TLS_STORE_TYPE="${AUTO_TLS_STORE_TYPE}"
TLS_KEY_ALGORITHM="${AUTO_TLS_KEY_ALGORITHM}"
TLS_KEY_SIZE="${AUTO_TLS_KEY_SIZE}"
TLS_DIGEST="${AUTO_TLS_DIGEST}"
TLS_CERT_DAYS="${AUTO_TLS_CERT_DAYS}"
TLS_KEY_PASSWORD="${AUTO_TLS_HOST_KEY_PASSWORD:-}"
TLS_KEYSTORE_PASSWORD="${AUTO_TLS_KEYSTORE_PASSWORD:-}"
TLS_TRUSTSTORE_PASSWORD="${AUTO_TLS_TRUSTSTORE_PASSWORD:-}"
TLS_DEMO_CA_CN="${AUTO_TLS_TEST_CA_CN}"
TLS_DEMO_CA_DAYS="${AUTO_TLS_TEST_CA_DAYS}"
TLS_DEMO_CA_KEY_PASSWORD="${AUTO_TLS_TEST_CA_KEY_PASSWORD}"
CM_HOST="${AUTO_TLS_CM_HOST:-}"
CM_PORT="${AUTO_TLS_CM_PORT}"
CM_API_VERSION="${AUTO_TLS_CM_API_VERSION}"
CM_USER="${AUTO_TLS_CM_USER:-}"
CM_PASSWORD="${AUTO_TLS_CM_PASSWORD:-}"
KEYS_DIR="${AUTO_TLS_KEY_DIR}"
CSRS_DIR="${AUTO_TLS_CSR_DIR}"
CERTS_DIR="${AUTO_TLS_CERT_DIR}"
FULLCHAINS_DIR="${AUTO_TLS_FULLCHAIN_DIR}"
STORES_DIR="${AUTO_TLS_STORE_DIR}"
CA_DIR="${AUTO_TLS_TEST_CA_DIR}"
OPENSSL_DIR="${AUTO_TLS_OPENSSL_DIR}"
PASSWORD_DIR="${AUTO_TLS_PASSWORD_DIR}"
CA_KEY="${AUTO_TLS_TEST_CA_KEY_FILE}"
CA_CERT="${AUTO_TLS_TEST_CA_CERT_FILE}"
CA_CHAIN="${AUTO_TLS_ISSUED_CA_CHAIN_FILE}"

fail() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Required command missing: $1"; }
require_file() { [[ -f "$1" ]] || fail "Required file not found: $1"; }
require_var() { local name="$1"; [[ -n "${!name:-}" ]] || fail "${name} is required"; }

validate_bool() {
  local name="$1" value="${!1:-}"
  [[ "${value}" == "true" || "${value}" == "false" ]] || fail "${name} must be true or false; current value: ${value}"
}

host_key_mode_label() {
  if [[ "${AUTO_TLS_ENCRYPT_HOST_KEYS}" == "true" ]]; then
    printf 'encrypted/password-protected'
  else
    printf 'unencrypted/no-password'
  fi
}

validate_password() {
  local name="$1" value="${!1:-}"
  [[ ${#value} -gt 12 ]] || fail "${name} must be longer than 12 characters"
  [[ "${value}" =~ ^[A-Za-z0-9]+$ ]] || fail "${name} must contain only letters and numbers for this Cloudera Auto-TLS flow"
}

validate_modes() {
  [[ "${AUTO_TLS_CERT_MODE}" == "customer" || "${AUTO_TLS_CERT_MODE}" == "test" ]] \
    || fail "AUTO_TLS_CERT_MODE must be customer or test"
  [[ "${AUTO_TLS_PREREQ_MODE}" == "full" || "${AUTO_TLS_PREREQ_MODE}" == "offline" ]] \
    || fail "AUTO_TLS_PREREQ_MODE must be full/online or offline"
  local bool_name
  for bool_name in \
    AUTO_TLS_ENCRYPT_HOST_KEYS AUTO_TLS_CONFIGURE_ALL_SERVICES AUTO_TLS_DRY_RUN \
    AUTO_TLS_AUTO_CREATE_HOSTS_CSV AUTO_TLS_AUTO_DISCOVER_IP_SANS \
    AUTO_TLS_ALLOW_TEST_CA_ENABLE AUTO_TLS_OVERWRITE_KEYS AUTO_TLS_OVERWRITE_TEST_CA \
    AUTO_TLS_OVERWRITE_ISSUED_CERTS AUTO_TLS_REQUIRE_CN_MATCH AUTO_TLS_DISALLOW_WILDCARDS \
    AUTO_TLS_REQUIRE_SUDO AUTO_TLS_PATHS_FROM_LOCATION AUTO_TLS_SSH_AUTO_SETUP \
    AUTO_TLS_SSH_PASSWORDLESS_SUDO AUTO_TLS_BOOTSTRAP_USE_DEFAULT_IDENTITIES \
    AUTO_TLS_BOOTSTRAP_REQUIRE_SUDO AUTO_TLS_SSH_SETUP_PLAN_ONLY AUTO_TLS_WAIT_FOR_COMMAND \
    AUTO_TLS_REQUIRE_LIVE_CONFIRMATION AUTO_TLS_AUTO_POST_RESTART \
    AUTO_TLS_POST_RESTART_MANAGEMENT_SERVICE AUTO_TLS_POST_RESTART_CLUSTERS \
    AUTO_TLS_POST_DEPLOY_CLIENT_CONFIG AUTO_TLS_REQUIRE_POST_RESTART_CONFIRMATION CURL_INSECURE; do
    validate_bool "${bool_name}"
  done
}

write_secret_file() {
  local value="$1" path="$2"
  umask 077
  mkdir -p "$(dirname "${path}")"
  printf '%s\n' "${value}" > "${path}"
  chmod "${AUTO_TLS_PRIVATE_FILE_MODE}" "${path}"
}

prepare_password_files() {
  require_var AUTO_TLS_KEYSTORE_PASSWORD
  require_var AUTO_TLS_TRUSTSTORE_PASSWORD
  validate_password AUTO_TLS_KEYSTORE_PASSWORD
  validate_password AUTO_TLS_TRUSTSTORE_PASSWORD
  write_secret_file "${AUTO_TLS_KEYSTORE_PASSWORD}" "${AUTO_TLS_KEYSTORE_PASSWORD_FILE}"
  write_secret_file "${AUTO_TLS_TRUSTSTORE_PASSWORD}" "${AUTO_TLS_TRUSTSTORE_PASSWORD_FILE}"

  if [[ "${AUTO_TLS_ENCRYPT_HOST_KEYS}" == "true" ]]; then
    require_var AUTO_TLS_HOST_KEY_PASSWORD
    validate_password AUTO_TLS_HOST_KEY_PASSWORD
    write_secret_file "${AUTO_TLS_HOST_KEY_PASSWORD}" "${AUTO_TLS_HOST_KEY_PASSWORD_FILE}"
  else
    rm -f "${AUTO_TLS_HOST_KEY_PASSWORD_FILE}"
  fi

  if [[ "${AUTO_TLS_CERT_MODE}" == "test" ]]; then
    require_var AUTO_TLS_TEST_CA_KEY_PASSWORD
    validate_password AUTO_TLS_TEST_CA_KEY_PASSWORD
    write_secret_file "${AUTO_TLS_TEST_CA_KEY_PASSWORD}" "${AUTO_TLS_TEST_CA_KEY_PASSWORD_FILE}"
  fi
}

prepare_dirs() {
  mkdir -p \
    "${AUTO_TLS_LOCATION}" "${AUTO_TLS_WORKDIR}" "${AUTO_TLS_KEY_DIR}" \
    "${AUTO_TLS_CSR_DIR}" "${AUTO_TLS_CERT_DIR}" "${AUTO_TLS_FULLCHAIN_DIR}" \
    "${AUTO_TLS_STORE_DIR}" "${AUTO_TLS_PAYLOAD_DIR}" "${AUTO_TLS_OPENSSL_DIR}" \
    "${AUTO_TLS_PASSWORD_DIR}" "${AUTO_TLS_TEST_CA_DIR}" "${AUTO_TLS_HOSTS_KEY_STORE_DIR}"

  chmod "${AUTO_TLS_LOCATION_MODE}" "${AUTO_TLS_LOCATION}"
  chmod "${AUTO_TLS_WORKDIR_MODE}" "${AUTO_TLS_WORKDIR}"
  chmod "${AUTO_TLS_PRIVATE_DIR_MODE}" \
    "${AUTO_TLS_KEY_DIR}" "${AUTO_TLS_PASSWORD_DIR}" "${AUTO_TLS_TEST_CA_DIR}" \
    "${AUTO_TLS_HOSTS_KEY_STORE_DIR}"
  chmod "${AUTO_TLS_WORKDIR_MODE}" \
    "${AUTO_TLS_CSR_DIR}" "${AUTO_TLS_CERT_DIR}" "${AUTO_TLS_FULLCHAIN_DIR}" \
    "${AUTO_TLS_STORE_DIR}" "${AUTO_TLS_PAYLOAD_DIR}" "${AUTO_TLS_OPENSSL_DIR}"

  prepare_password_files
}

host_key() { echo "${AUTO_TLS_KEY_DIR}/$1-key.pem"; }
host_csr() { echo "${AUTO_TLS_CSR_DIR}/$1-csr.pem"; }
host_cert() { echo "${AUTO_TLS_CERT_DIR}/$1-cert.pem"; }
host_fullchain() { echo "${AUTO_TLS_FULLCHAIN_DIR}/$1-fullchain.pem"; }
host_keystore() { echo "${AUTO_TLS_STORE_DIR}/$1-keystore.p12"; }
host_truststore() { echo "${AUTO_TLS_STORE_DIR}/$1-truststore.p12"; }
host_openssl_cnf() { echo "${AUTO_TLS_OPENSSL_DIR}/$1-openssl.cnf"; }

apply_owner_if_available() {
  if id "${CLOUDERA_SERVICE_USER}" >/dev/null 2>&1; then
    chown -R "${AUTO_TLS_OWNER}" "${AUTO_TLS_LOCATION}"
  else
    warn "${CLOUDERA_SERVICE_USER} user not found; retaining current ownership"
  fi
}

ensure_hosts_csv() {
  if [[ -s "${AUTO_TLS_HOSTS_CSV}" ]]; then
    return 0
  fi
  [[ "${AUTO_TLS_AUTO_CREATE_HOSTS_CSV}" == "true" ]] \
    || fail "Hosts inventory not found: ${AUTO_TLS_HOSTS_CSV}. Create it from hosts.csv.example or enable AUTO_TLS_AUTO_CREATE_HOSTS_CSV."

  local normalized host
  normalized="${AUTO_TLS_HOST_LIST//,/ }"
  normalized="${normalized//;/ }"
  local hosts=()
  declare -A seen=()
  for host in ${AUTO_TLS_CM_HOST:-} ${normalized}; do
    [[ -n "${host}" ]] || continue
    if [[ -z "${seen[${host}]:-}" ]]; then
      hosts+=("${host}")
      seen["${host}"]=1
    fi
  done
  [[ ${#hosts[@]} -gt 0 ]] \
    || fail "Cannot auto-create hosts.csv because AUTO_TLS_CM_HOST and AUTO_TLS_HOST_LIST are empty"

  mkdir -p "$(dirname "${AUTO_TLS_HOSTS_CSV}")"
  local tmp="${AUTO_TLS_HOSTS_CSV}.tmp.$$"
  {
    printf 'host_id,common_name,dns_sans,ip_sans\n'
    for host in "${hosts[@]}"; do
      local dns_sans='' ip_sans=''
      if "${SYSTEM_PYTHON_BIN}" - "${host}" <<'PYIN' >/dev/null 2>&1
import ipaddress
import sys
ipaddress.ip_address(sys.argv[1])
PYIN
      then
        ip_sans="${host}"
      else
        dns_sans="${host}"
        if [[ "${AUTO_TLS_AUTO_DISCOVER_IP_SANS}" == "true" ]]; then
          ip_sans="$(getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd';' - || true)"
        fi
      fi
      printf '%s,%s,%s,%s\n' "${host}" "${host}" "${dns_sans}" "${ip_sans}"
    done
  } > "${tmp}"
  chmod 0640 "${tmp}"
  mv -f "${tmp}" "${AUTO_TLS_HOSTS_CSV}"
  echo "[OK] Auto-created host inventory: ${AUTO_TLS_HOSTS_CSV}"
  echo "[INFO] Review hosts.csv and add any load balancer, VIP, alias, or additional SAN entries before requesting production certificates."
}

is_local_host() {
  local host="$1" local_fqdn local_short
  local_fqdn="$(hostname -f 2>/dev/null || hostname)"
  local_short="$(hostname -s 2>/dev/null || hostname)"
  [[ "${host}" == "${local_fqdn}" || "${host}" == "${local_short}" || "${host}" == "localhost" ]] && return 0

  local host_ip local_ip
  while read -r host_ip; do
    [[ -z "${host_ip}" ]] && continue
    while read -r local_ip; do
      [[ "${host_ip}" == "${local_ip}" ]] && return 0
    done < <(hostname -I 2>/dev/null | tr ' ' '\n')
  done < <(getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1}' | sort -u)
  return 1
}

read_host_ids() {
  ensure_hosts_csv
  "${SYSTEM_PYTHON_BIN}" - "${AUTO_TLS_HOSTS_CSV}" <<'PY'
import csv
import sys
with open(sys.argv[1], newline="") as handle:
    reader = csv.DictReader(handle)
    if not reader.fieldnames:
        raise SystemExit("[ERROR] hosts.csv has no header row")
    count = 0
    for row in reader:
        host = (row.get("host_id") or row.get("hostname") or row.get("host") or "").strip()
        if host and not host.startswith("#"):
            print(host)
            count += 1
    if count == 0:
        raise SystemExit("[ERROR] No hosts found in hosts.csv")
PY
}

# Embedded Python helpers read configuration from the environment.
while IFS= read -r auto_tls_var; do
  export "${auto_tls_var}"
done < <(compgen -A variable AUTO_TLS_)
export SYSTEM_PYTHON_BIN OPENSSL_BIN KEYTOOL CURL_INSECURE CM_HTTPS_SCHEME
export CM_SERVER_SERVICE CM_AGENT_SERVICE CLOUDERA_SERVICE_USER SCRIPT_DIR TOP_LEVEL_DIR

validate_modes
