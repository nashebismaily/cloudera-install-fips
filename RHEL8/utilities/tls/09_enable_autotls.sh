#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_var AUTO_TLS_CM_HOST
require_var AUTO_TLS_HOSTS_CSV
ensure_hosts_csv
require_file "${AUTO_TLS_ISSUED_CA_CHAIN_FILE}"
prepare_dirs

if [[ "${AUTO_TLS_CERT_MODE}" == "test" && "${AUTO_TLS_DRY_RUN}" != "true" && "${AUTO_TLS_ALLOW_TEST_CA_ENABLE}" != "true" ]]; then
  fail "Refusing to enable Cloudera Manager with the test CA. Use customer certificates or explicitly set AUTO_TLS_ALLOW_TEST_CA_ENABLE=true for an isolated lab."
fi

if [[ "${AUTO_TLS_DRY_RUN}" != "true" ]]; then
  require_var AUTO_TLS_CM_USER
  require_var AUTO_TLS_CM_PASSWORD
  require_var AUTO_TLS_SSH_USER
  if [[ -z "${AUTO_TLS_SSH_KEY_FILE}" && -z "${AUTO_TLS_SSH_PASSWORD}" ]]; then
    fail "Set AUTO_TLS_SSH_KEY_FILE or AUTO_TLS_SSH_PASSWORD for the live Auto-TLS command"
  fi
fi

CM_CERT="${AUTO_TLS_CERT_DIR}/${AUTO_TLS_CM_HOST}-cert.pem"
CM_KEY="${AUTO_TLS_KEY_DIR}/${AUTO_TLS_CM_HOST}-key.pem"
require_file "${CM_CERT}"
require_file "${CM_KEY}"

"${SYSTEM_PYTHON_BIN}" - <<'PY'
import csv
import os
import subprocess
from pathlib import Path

hosts_csv = Path(os.environ["AUTO_TLS_HOSTS_CSV"])
key_dir = Path(os.environ["AUTO_TLS_KEY_DIR"])
openssl_bin = os.environ["OPENSSL_BIN"]
encrypt_keys = os.environ["AUTO_TLS_ENCRYPT_HOST_KEYS"] == "true"
password_file = Path(os.environ["AUTO_TLS_HOST_KEY_PASSWORD_FILE"])

def command_succeeds(cmd):
    result = subprocess.run(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=False,
    )
    return result.returncode == 0


def assert_key_protection_mode(path, host_id):
    """Require the actual PEM key protection to match AUTO_TLS_ENCRYPT_HOST_KEYS."""
    empty_password_cmd = [
        openssl_bin, "pkey", "-in", str(path),
        "-passin", "pass:", "-check", "-noout",
    ]
    readable_without_password = command_succeeds(empty_password_cmd)

    if encrypt_keys:
        if readable_without_password:
            raise SystemExit(
                f"[ERROR] Private key for {host_id} is unencrypted, but "
                "AUTO_TLS_ENCRYPT_HOST_KEYS=true. Set the flag to false for a "
                "customer-supplied key without a password, or replace the key "
                "with an encrypted key."
            )
        if not password_file.is_file():
            raise SystemExit(
                f"[ERROR] Host-key password file is missing for encrypted key {host_id}: "
                f"{password_file}"
            )
        password_cmd = [
            openssl_bin, "pkey", "-in", str(path),
            "-passin", f"file:{password_file}", "-check", "-noout",
        ]
        if not command_succeeds(password_cmd):
            raise SystemExit(
                f"[ERROR] Private key for {host_id} is encrypted, but the configured "
                "AUTO_TLS_HOST_KEY_PASSWORD cannot read it."
            )
        return

    if not readable_without_password:
        raise SystemExit(
            f"[ERROR] Private key for {host_id} is encrypted or unreadable, but "
            "AUTO_TLS_ENCRYPT_HOST_KEYS=false. Set the flag to true and provide "
            "AUTO_TLS_HOST_KEY_PASSWORD, or supply an unencrypted private key."
        )


with hosts_csv.open(newline="") as f:
    reader = csv.DictReader(f)
    count = 0
    for row in reader:
        host = (row.get("host_id") or row.get("hostname") or row.get("host") or "").strip()
        if not host or host.startswith("#"):
            continue
        key_path = key_dir / f"{host}-key.pem"
        if not key_path.is_file():
            raise SystemExit(f"[ERROR] Missing key for {host}: {key_path}")
        assert_key_protection_mode(key_path, host)
        mode = "encrypted/password-protected" if encrypt_keys else "unencrypted/no-password"
        print(f"[PASS] Private key is readable for {host} ({mode})")
        count += 1
if count < 1:
    raise SystemExit("[ERROR] No hosts found in hosts.csv")
PY

# Cert Manager needs one password file per encrypted host key.
"${SYSTEM_PYTHON_BIN}" - <<'PY'
import csv
import os
from pathlib import Path

hosts_csv = Path(os.environ["AUTO_TLS_HOSTS_CSV"])
base = Path(os.environ["AUTO_TLS_HOSTS_KEY_STORE_DIR"])
filename = os.environ["AUTO_TLS_HOST_KEY_PASSWORD_FILENAME"]
encrypt_keys = os.environ["AUTO_TLS_ENCRYPT_HOST_KEYS"] == "true"
password = os.environ.get("AUTO_TLS_HOST_KEY_PASSWORD", "")
mode = int(os.environ["AUTO_TLS_PRIVATE_FILE_MODE"], 8)

with hosts_csv.open(newline="") as f:
    for row in csv.DictReader(f):
        host = (row.get("host_id") or row.get("hostname") or row.get("host") or "").strip()
        if not host or host.startswith("#"):
            continue
        host_dir = base / host
        host_dir.mkdir(parents=True, exist_ok=True)
        host_dir.chmod(0o700)
        pw_file = host_dir / filename
        if encrypt_keys:
            pw_file.write_text(password + "\n")
            pw_file.chmod(mode)
            print(f"[INFO] Wrote host key password file: {pw_file}")
        elif pw_file.exists():
            pw_file.unlink()
            print(f"[INFO] Removed stale password file: {pw_file}")
PY

# Build the exact generateCmca payload from the staged customer/test artifacts.
"${SYSTEM_PYTHON_BIN}" - <<'PY'
import csv
import json
import os
from pathlib import Path

hosts_csv = Path(os.environ["AUTO_TLS_HOSTS_CSV"])
key_dir = Path(os.environ["AUTO_TLS_KEY_DIR"])
cert_dir = Path(os.environ["AUTO_TLS_CERT_DIR"])
payload_file = Path(os.environ["AUTO_TLS_PAYLOAD_FILE"])
cm_host = os.environ["AUTO_TLS_CM_HOST"]
ssh_private_key_file = os.environ.get("AUTO_TLS_SSH_KEY_FILE", "")
ssh_password = os.environ.get("AUTO_TLS_SSH_PASSWORD", "")

host_certs = []
with hosts_csv.open(newline="") as f:
    reader = csv.DictReader(f)
    if not reader.fieldnames:
        raise SystemExit("[ERROR] hosts.csv has no header row")
    for row in reader:
        host = (row.get("host_id") or row.get("hostname") or row.get("host") or "").strip()
        if not host or host.startswith("#"):
            continue
        cert_path = cert_dir / f"{host}-cert.pem"
        key_path = key_dir / f"{host}-key.pem"
        if not cert_path.is_file() or not key_path.is_file():
            raise SystemExit(f"[ERROR] Missing certificate/key for {host}")
        host_certs.append({"hostname": host, "certificate": str(cert_path), "key": str(key_path)})
if not host_certs:
    raise SystemExit("[ERROR] No hosts found in hosts.csv")
if cm_host not in {entry["hostname"] for entry in host_certs}:
    raise SystemExit(f"[ERROR] CM host {cm_host} is not included in hosts.csv")

payload = {
    "location": os.environ["AUTO_TLS_LOCATION"],
    "customCA": True,
    "interpretAsFilenames": True,
    "cmHostCert": str(cert_dir / f"{cm_host}-cert.pem"),
    "cmHostKey": str(key_dir / f"{cm_host}-key.pem"),
    "caCert": os.environ["AUTO_TLS_ISSUED_CA_CHAIN_FILE"],
    "keystorePasswd": os.environ["AUTO_TLS_KEYSTORE_PASSWORD_FILE"],
    "truststorePasswd": os.environ["AUTO_TLS_TRUSTSTORE_PASSWORD_FILE"],
    "hostCerts": host_certs,
    "configureAllServices": os.environ["AUTO_TLS_CONFIGURE_ALL_SERVICES"] == "true",
    "sshPort": int(os.environ["AUTO_TLS_SSH_PORT"]),
    "userName": os.environ.get("AUTO_TLS_SSH_USER", ""),
}
if ssh_private_key_file:
    key_path = Path(ssh_private_key_file)
    if not key_path.is_file():
        raise SystemExit(f"[ERROR] SSH private key does not exist: {key_path}")
    payload["privateKey"] = key_path.read_text()
elif ssh_password:
    payload["password"] = ssh_password
elif os.environ["AUTO_TLS_DRY_RUN"] == "true":
    payload["password"] = ""
else:
    raise SystemExit("[ERROR] Missing Auto-TLS SSH credential")

payload_file.parent.mkdir(parents=True, exist_ok=True)
payload_file.write_text(json.dumps(payload, indent=2) + "\n")
payload_file.chmod(0o600)
print(f"[INFO] Payload written: {payload_file}")
print(f"[INFO] Hosts included: {len(host_certs)}")
PY

apply_owner_if_available
chmod "${AUTO_TLS_PRIVATE_FILE_MODE}" \
  "${AUTO_TLS_KEYSTORE_PASSWORD_FILE}" \
  "${AUTO_TLS_TRUSTSTORE_PASSWORD_FILE}" \
  "${AUTO_TLS_PAYLOAD_FILE}" \
  "${AUTO_TLS_KEY_DIR}"/*-key.pem
if [[ "${AUTO_TLS_ENCRYPT_HOST_KEYS}" == "true" ]]; then
  chmod "${AUTO_TLS_PRIVATE_FILE_MODE}" \
    "${AUTO_TLS_HOST_KEY_PASSWORD_FILE}" \
    "${AUTO_TLS_HOSTS_KEY_STORE_DIR}"/*/"${AUTO_TLS_HOST_KEY_PASSWORD_FILENAME}" 2>/dev/null || true
fi

echo "[INFO] Payload summary:"
"${SYSTEM_PYTHON_BIN}" - <<'PY'
import json
import os
from pathlib import Path
payload = json.loads(Path(os.environ["AUTO_TLS_PAYLOAD_FILE"]).read_text())
if "privateKey" in payload:
    payload["privateKey"] = "[REDACTED]"
if "password" in payload:
    payload["password"] = "[REDACTED]"
print(json.dumps(payload, indent=2))
PY

if [[ "${AUTO_TLS_DRY_RUN}" == "true" ]]; then
  if [[ "${AUTO_TLS_ENCRYPT_HOST_KEYS}" == "true" ]]; then
    echo "[OK] Dry run completed. Payload and encrypted-key password files were generated and validated."
  else
    echo "[OK] Dry run completed. Payload was generated and validated for unencrypted host keys; no host-key password files were created."
  fi
  echo "[INFO] No Cloudera Manager API call was made."
  exit 0
fi

if [[ "${AUTO_TLS_REQUIRE_LIVE_CONFIRMATION}" == "true" && "${AUTO_TLS_CONFIRM_LIVE}" != "ENABLE-AUTOTLS" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Type ENABLE-AUTOTLS to submit the live Cloudera Manager command: " AUTO_TLS_CONFIRM_LIVE
  fi
  [[ "${AUTO_TLS_CONFIRM_LIVE}" == "ENABLE-AUTOTLS" ]] \
    || fail "Live Auto-TLS submission was not confirmed. Set AUTO_TLS_CONFIRM_LIVE=ENABLE-AUTOTLS or enter the confirmation when prompted."
fi

CM_AUTOTLS_ENDPOINT="${AUTO_TLS_CM_SCHEME}://${AUTO_TLS_CM_HOST}:${AUTO_TLS_CM_PORT}/api/${AUTO_TLS_CM_API_VERSION}${AUTO_TLS_GENERATE_CMCA_PATH}"
curl_args=(-sS)
[[ "${CURL_INSECURE}" == "true" ]] && curl_args+=(-k)
HTTP_CODE="$(curl "${curl_args[@]}" -o "${AUTO_TLS_HTTP_RESPONSE_FILE}" -w '%{http_code}' \
  -u "${AUTO_TLS_CM_USER}:${AUTO_TLS_CM_PASSWORD}" -X POST \
  --header 'Content-Type: application/json' --header 'Accept: application/json' \
  -d @"${AUTO_TLS_PAYLOAD_FILE}" "${CM_AUTOTLS_ENDPOINT}" || true)"

echo "[INFO] Auto-TLS endpoint: ${CM_AUTOTLS_ENDPOINT}"
echo "[INFO] HTTP status: ${HTTP_CODE}"
cat "${AUTO_TLS_HTTP_RESPONSE_FILE}" || true

success=false
read -r -a success_codes <<< "${AUTO_TLS_SUCCESS_HTTP_CODES}"
for success_code in "${success_codes[@]}"; do
  [[ "${HTTP_CODE}" == "${success_code}" ]] && success=true
done
if [[ "${success}" != "true" ]]; then
  echo "[ERROR] Auto-TLS API call failed."
  echo "[INFO] Server log: ${AUTO_TLS_SERVER_LOG_FILE}"
  echo "[INFO] Cert Manager log: ${AUTO_TLS_CERTMANAGER_LOG_FILE}"
  exit 1
fi

COMMAND_ID="$("${SYSTEM_PYTHON_BIN}" - "${AUTO_TLS_HTTP_RESPONSE_FILE}" <<'PY'
import json
import sys
try:
    with open(sys.argv[1]) as handle:
        data = json.load(handle)
except Exception:
    print("")
    raise SystemExit(0)
value = data.get("id", "")
print(value if value is not None else "")
PY
)"

if [[ "${AUTO_TLS_WAIT_FOR_COMMAND}" == "true" && -n "${COMMAND_ID}" ]]; then
  echo "[INFO] Waiting for Cloudera Manager command ${COMMAND_ID}"
  COMMAND_URL="${AUTO_TLS_CM_SCHEME}://${AUTO_TLS_CM_HOST}:${AUTO_TLS_CM_PORT}/api/${AUTO_TLS_CM_API_VERSION}${AUTO_TLS_COMMAND_STATUS_PATH}/${COMMAND_ID}"
  deadline=$((SECONDS + AUTO_TLS_COMMAND_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    STATUS_FILE="${AUTO_TLS_PAYLOAD_DIR}/command-${COMMAND_ID}-status.json"
    STATUS_HTTP="$(curl "${curl_args[@]}" -o "${STATUS_FILE}" -w '%{http_code}' \
      -u "${AUTO_TLS_CM_USER}:${AUTO_TLS_CM_PASSWORD}" "${COMMAND_URL}" || true)"
    if [[ "${STATUS_HTTP}" != "200" ]]; then
      echo "[WARN] Command status request returned HTTP ${STATUS_HTTP}; retrying"
      sleep "${AUTO_TLS_COMMAND_POLL_SECONDS}"
      continue
    fi

    IFS=$'\t' read -r COMMAND_ACTIVE COMMAND_SUCCESS COMMAND_MESSAGE < <(
      "${SYSTEM_PYTHON_BIN}" - "${STATUS_FILE}" <<'PY'
import json
import sys
with open(sys.argv[1]) as handle:
    data = json.load(handle)
active = data.get("active")
success = data.get("success")
message = str(data.get("resultMessage") or data.get("message") or "").replace("\t", " ").replace("\n", " ")
def value(item):
    if item is True:
        return "true"
    if item is False:
        return "false"
    return "unknown"
print("%s\t%s\t%s" % (value(active), value(success), message))
PY
    )

    echo "[INFO] Command ${COMMAND_ID}: active=${COMMAND_ACTIVE} success=${COMMAND_SUCCESS}${COMMAND_MESSAGE:+ message=${COMMAND_MESSAGE}}"
    if [[ "${COMMAND_ACTIVE}" == "false" ]]; then
      if [[ "${COMMAND_SUCCESS}" == "true" ]]; then
        echo "[OK] Auto-TLS command completed successfully."
        break
      fi
      echo "[ERROR] Auto-TLS command completed unsuccessfully."
      cat "${STATUS_FILE}" || true
      exit 1
    fi
    sleep "${AUTO_TLS_COMMAND_POLL_SECONDS}"
  done
  if (( SECONDS >= deadline )); then
    fail "Timed out waiting for Auto-TLS command ${COMMAND_ID} after ${AUTO_TLS_COMMAND_TIMEOUT_SECONDS} seconds"
  fi
elif [[ "${AUTO_TLS_WAIT_FOR_COMMAND}" == "true" ]]; then
  echo "[WARN] Auto-TLS API accepted the request, but no command ID was returned; check Cloudera Manager command history before restarting."
else
  echo "[OK] Auto-TLS command submitted successfully."
fi

echo "[INFO] Server log: ${AUTO_TLS_SERVER_LOG_FILE}"
echo "[INFO] Cert Manager log: ${AUTO_TLS_CERTMANAGER_LOG_FILE}"
echo "[INFO] Next step: bash 10_post_enable_restart.sh"
echo "[INFO] HTTPS URL after restart: ${CM_HTTPS_SCHEME}://${AUTO_TLS_CM_HOST}:${AUTO_TLS_CM_HTTPS_PORT}"

if [[ "${AUTO_TLS_AUTO_POST_RESTART}" == "true" ]]; then
  bash "${SCRIPT_DIR}/10_post_enable_restart.sh"
fi
