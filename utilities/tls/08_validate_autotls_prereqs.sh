#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_var AUTO_TLS_CM_HOST
require_var AUTO_TLS_HOSTS_CSV
ensure_hosts_csv
prepare_dirs

echo "[INFO] Validating Auto-TLS prerequisites"
echo "[INFO] Mode: ${AUTO_TLS_PREREQ_MODE}"
echo "[INFO] Certificate source: ${AUTO_TLS_CERT_MODE}"
echo "[INFO] Host private-key mode: $(host_key_mode_label)"
echo "[INFO] CM endpoint: ${AUTO_TLS_CM_SCHEME}://${AUTO_TLS_CM_HOST}:${AUTO_TLS_CM_PORT}"
echo "[INFO] AUTO_TLS_LOCATION=${AUTO_TLS_LOCATION}"

read -r -a required_commands <<< "${AUTO_TLS_REQUIRED_COMMANDS}"
for command_name in "${required_commands[@]}"; do
  if [[ "${AUTO_TLS_PREREQ_MODE}" == "offline" && ( "${command_name}" == "curl" || "${command_name}" == "ssh" || "${command_name}" == "getent" ) ]]; then
    continue
  fi
  command -v "${command_name}" >/dev/null 2>&1 \
    || { echo "[ERROR] Required command not found: ${command_name}"; exit 1; }
done
[[ -n "${KEYTOOL}" && -x "${KEYTOOL}" ]] || { echo "[ERROR] keytool not found: ${KEYTOOL}"; exit 1; }
echo "[PASS] Required local commands found"

password_names=(AUTO_TLS_KEYSTORE_PASSWORD AUTO_TLS_TRUSTSTORE_PASSWORD)
[[ "${AUTO_TLS_ENCRYPT_HOST_KEYS}" == "true" ]] && password_names+=(AUTO_TLS_HOST_KEY_PASSWORD)
[[ "${AUTO_TLS_CERT_MODE}" == "test" ]] && password_names+=(AUTO_TLS_TEST_CA_KEY_PASSWORD)
for password_name in "${password_names[@]}"; do
  validate_password "${password_name}"
done
echo "[PASS] Auto-TLS passwords meet Cloudera flow requirements"

"${SYSTEM_PYTHON_BIN}" - <<'PY' > "${AUTO_TLS_HOSTS_CHECK_FILE}"
import csv
import os
from pathlib import Path
hosts_csv = Path(os.environ["AUTO_TLS_HOSTS_CSV"])
cm_host = os.environ["AUTO_TLS_CM_HOST"]
seen = set()
with hosts_csv.open(newline="") as f:
    reader = csv.DictReader(f)
    if not reader.fieldnames:
        raise SystemExit("[ERROR] hosts.csv has no header row")
    for row in reader:
        host = (row.get("host_id") or row.get("hostname") or row.get("host") or "").strip()
        if not host or host.startswith("#"):
            continue
        if host in seen:
            raise SystemExit(f"[ERROR] Duplicate host in hosts.csv: {host}")
        seen.add(host)
        print(host)
if not seen:
    raise SystemExit("[ERROR] No hosts found in hosts.csv")
if cm_host not in seen:
    raise SystemExit(f"[ERROR] AUTO_TLS_CM_HOST={cm_host} is not a host_id in hosts.csv")
PY
HOST_COUNT="$(wc -l < "${AUTO_TLS_HOSTS_CHECK_FILE}" | tr -d ' ')"
echo "[PASS] hosts.csv contains ${HOST_COUNT} unique host(s), including the manager"

MISSING=0
[[ -f "${AUTO_TLS_ISSUED_CA_CHAIN_FILE}" ]] \
  && echo "[PASS] CA chain found: ${AUTO_TLS_ISSUED_CA_CHAIN_FILE}" \
  || { echo "[ERROR] CA chain not found: ${AUTO_TLS_ISSUED_CA_CHAIN_FILE}"; MISSING=1; }
while read -r host; do
  [[ -z "${host}" ]] && continue
  for artifact in \
    "${AUTO_TLS_KEY_DIR}/${host}-key.pem" \
    "${AUTO_TLS_CSR_DIR}/${host}-csr.pem" \
    "${AUTO_TLS_CERT_DIR}/${host}-cert.pem" \
    "${AUTO_TLS_FULLCHAIN_DIR}/${host}-fullchain.pem" \
    "${AUTO_TLS_STORE_DIR}/${host}-keystore.p12" \
    "${AUTO_TLS_STORE_DIR}/${host}-truststore.p12"; do
    [[ -f "${artifact}" ]] || { echo "[ERROR] Required artifact missing: ${artifact}"; MISSING=1; }
  done
done < "${AUTO_TLS_HOSTS_CHECK_FILE}"
[[ "${MISSING}" -eq 0 ]] || exit 1
echo "[PASS] All required certificate artifacts are present"

if [[ "${AUTO_TLS_PREREQ_MODE}" == "offline" ]]; then
  echo "[WARN] Offline prerequisite mode skips DNS, CM API, SSH, sudo, and service-user access checks."
  echo "[PASS] Offline Auto-TLS prerequisite validation completed"
  exit 0
fi

require_var AUTO_TLS_CM_USER
require_var AUTO_TLS_CM_PASSWORD
require_var AUTO_TLS_SSH_USER
[[ -n "${AUTO_TLS_SSH_KEY_FILE}" ]] || fail "AUTO_TLS_SSH_KEY_FILE is required for noninteractive full prerequisite validation"
require_file "${AUTO_TLS_SSH_KEY_FILE}"

while read -r host; do
  [[ -z "${host}" ]] && continue
  getent hosts "${host}" >/dev/null 2>&1 \
    && echo "[PASS] Host resolves: ${host}" \
    || { echo "[ERROR] Host does not resolve: ${host}"; exit 1; }
done < "${AUTO_TLS_HOSTS_CHECK_FILE}"

CM_VERSION_URL="${AUTO_TLS_CM_SCHEME}://${AUTO_TLS_CM_HOST}:${AUTO_TLS_CM_PORT}/api/${AUTO_TLS_CM_API_VERSION}${AUTO_TLS_CM_VERSION_PATH}"
CM_AUTOTLS_URL="${AUTO_TLS_CM_SCHEME}://${AUTO_TLS_CM_HOST}:${AUTO_TLS_CM_PORT}/api/${AUTO_TLS_CM_API_VERSION}${AUTO_TLS_GENERATE_CMCA_PATH}"
curl_args=(-sS)
[[ "${CURL_INSECURE}" == "true" ]] && curl_args+=(-k)
HTTP_CODE="$(curl "${curl_args[@]}" -o "${AUTO_TLS_CM_VERSION_RESPONSE_FILE}" -w '%{http_code}' \
  -u "${AUTO_TLS_CM_USER}:${AUTO_TLS_CM_PASSWORD}" "${CM_VERSION_URL}" || true)"
if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "[ERROR] CM API version check failed. HTTP status: ${HTTP_CODE}"
  cat "${AUTO_TLS_CM_VERSION_RESPONSE_FILE}" || true
  exit 1
fi
echo "[PASS] CM API credentials worked"
echo "[INFO] Auto-TLS endpoint: ${CM_AUTOTLS_URL}"

SSH_OPTS=(
  -p "${AUTO_TLS_SSH_PORT}"
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o "ConnectTimeout=${AUTO_TLS_SSH_CONNECT_TIMEOUT_SECONDS}"
  -i "${AUTO_TLS_SSH_KEY_FILE}"
  -o IdentitiesOnly=yes
)
while read -r host; do
  [[ -z "${host}" ]] && continue
  remote_command='hostname -f'
  [[ "${AUTO_TLS_REQUIRE_SUDO}" == "true" ]] && remote_command='hostname -f && sudo -n true'
  if "${AUTO_TLS_SSH_BIN}" -n "${SSH_OPTS[@]}" "${AUTO_TLS_SSH_USER}@${host}" "${remote_command}" \
      >"${AUTO_TLS_SSH_TEST_OUTPUT_FILE}" 2>"${AUTO_TLS_SSH_TEST_ERROR_FILE}"; then
    echo "[PASS] SSH$( [[ "${AUTO_TLS_REQUIRE_SUDO}" == "true" ]] && printf '/sudo' ) works: ${AUTO_TLS_SSH_USER}@${host}"
  else
    echo "[ERROR] Passwordless SSH/sudo failed for ${AUTO_TLS_SSH_USER}@${host}"
    cat "${AUTO_TLS_SSH_TEST_ERROR_FILE}" || true
    exit 1
  fi
done < "${AUTO_TLS_HOSTS_CHECK_FILE}"

if id "${CLOUDERA_SERVICE_USER}" >/dev/null 2>&1; then
  apply_owner_if_available
  service_read_paths=(
    "${AUTO_TLS_LOCATION}"
    "${AUTO_TLS_ISSUED_CA_CHAIN_FILE}"
    "${AUTO_TLS_KEY_DIR}/${AUTO_TLS_CM_HOST}-key.pem"
    "${AUTO_TLS_CERT_DIR}/${AUTO_TLS_CM_HOST}-cert.pem"
    "${AUTO_TLS_KEYSTORE_PASSWORD_FILE}"
    "${AUTO_TLS_TRUSTSTORE_PASSWORD_FILE}"
  )
  [[ "${AUTO_TLS_ENCRYPT_HOST_KEYS}" == "true" ]] && service_read_paths+=("${AUTO_TLS_HOST_KEY_PASSWORD_FILE}")
  for path in "${service_read_paths[@]}"; do
    runuser -u "${CLOUDERA_SERVICE_USER}" -- test -r "${path}" \
      || { echo "[ERROR] ${CLOUDERA_SERVICE_USER} cannot read ${path}"; exit 1; }
  done
  runuser -u "${CLOUDERA_SERVICE_USER}" -- test -w "${AUTO_TLS_LOCATION}" \
    || { echo "[ERROR] ${CLOUDERA_SERVICE_USER} cannot write ${AUTO_TLS_LOCATION}"; exit 1; }
  echo "[PASS] ${CLOUDERA_SERVICE_USER} can read required artifacts and write AUTO_TLS_LOCATION"
else
  echo "[ERROR] Required Cloudera service user does not exist: ${CLOUDERA_SERVICE_USER}"
  exit 1
fi

echo "[PASS] Full Auto-TLS prerequisite validation completed"
