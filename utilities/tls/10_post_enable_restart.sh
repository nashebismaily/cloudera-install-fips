#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

if [[ "${EUID}" -ne 0 ]]; then
  fail "Run this script as root on the Cloudera Manager server"
fi
require_var AUTO_TLS_CM_HOST
require_var AUTO_TLS_CM_USER
require_var AUTO_TLS_CM_PASSWORD
ensure_hosts_csv
require_file "${AUTO_TLS_SSH_KEY_FILE}"

if [[ "${AUTO_TLS_REQUIRE_POST_RESTART_CONFIRMATION}" == "true" && "${AUTO_TLS_CONFIRM_POST_RESTART}" != "RESTART-AUTOTLS" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Type RESTART-AUTOTLS to restart CM, agents, management service, and clusters: " AUTO_TLS_CONFIRM_POST_RESTART
  fi
  [[ "${AUTO_TLS_CONFIRM_POST_RESTART}" == "RESTART-AUTOTLS" ]] \
    || fail "Post-enable restart was not confirmed"
fi

curl_args=(-sS)
[[ "${CURL_INSECURE}" == "true" ]] && curl_args+=(-k)
HTTPS_BASE="${CM_HTTPS_SCHEME}://${AUTO_TLS_CM_HOST}:${AUTO_TLS_CM_HTTPS_PORT}/api/${AUTO_TLS_CM_API_VERSION}"

wait_for_cm_https() {
  local deadline=$((SECONDS + AUTO_TLS_HTTPS_WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    if curl "${curl_args[@]}" -u "${AUTO_TLS_CM_USER}:${AUTO_TLS_CM_PASSWORD}" \
      "${HTTPS_BASE}${AUTO_TLS_CM_VERSION_PATH}" >/dev/null 2>&1; then
      echo "[PASS] Cloudera Manager HTTPS API is responding"
      return 0
    fi
    echo "[INFO] Waiting for Cloudera Manager HTTPS..."
    sleep 10
  done
  fail "Timed out waiting for Cloudera Manager HTTPS after ${AUTO_TLS_HTTPS_WAIT_SECONDS} seconds"
}

poll_command() {
  local command_id="$1" label="$2"
  [[ -n "${command_id}" ]] || { echo "[WARN] ${label} returned no command ID"; return 0; }
  local deadline=$((SECONDS + AUTO_TLS_COMMAND_TIMEOUT_SECONDS))
  local status_file="${AUTO_TLS_PAYLOAD_DIR}/post-command-${command_id}.json"
  while (( SECONDS < deadline )); do
    local http
    http="$(curl "${curl_args[@]}" -o "${status_file}" -w '%{http_code}' \
      -u "${AUTO_TLS_CM_USER}:${AUTO_TLS_CM_PASSWORD}" \
      "${HTTPS_BASE}${AUTO_TLS_COMMAND_STATUS_PATH}/${command_id}" || true)"
    if [[ "${http}" != "200" ]]; then
      echo "[WARN] ${label} status HTTP ${http}; retrying"
      sleep "${AUTO_TLS_COMMAND_POLL_SECONDS}"
      continue
    fi
    IFS=$'\t' read -r active success message < <(
      "${SYSTEM_PYTHON_BIN}" - "${status_file}" <<'PY'
import json
import sys
with open(sys.argv[1]) as handle:
    data = json.load(handle)
def val(v):
    if v is True:
        return "true"
    if v is False:
        return "false"
    return "unknown"
message = str(data.get("resultMessage") or data.get("message") or "").replace("\t", " ").replace("\n", " ")
print("%s\t%s\t%s" % (val(data.get("active")), val(data.get("success")), message))
PY
    )
    echo "[INFO] ${label}: active=${active} success=${success}${message:+ message=${message}}"
    if [[ "${active}" == "false" ]]; then
      [[ "${success}" == "true" ]] || { cat "${status_file}"; fail "${label} failed"; }
      echo "[OK] ${label} completed"
      return 0
    fi
    sleep "${AUTO_TLS_COMMAND_POLL_SECONDS}"
  done
  fail "Timed out waiting for ${label}"
}

submit_post_command() {
  local url="$1" label="$2" body="${3:-}"
  local response="${AUTO_TLS_PAYLOAD_DIR}/$(echo "${label}" | tr ' /' '__').json"
  local args=("${curl_args[@]}" -o "${response}" -w '%{http_code}' \
    -u "${AUTO_TLS_CM_USER}:${AUTO_TLS_CM_PASSWORD}" -X POST \
    --header 'Content-Type: application/json' --header 'Accept: application/json')
  [[ -n "${body}" ]] && args+=( -d "${body}" )
  local http
  http="$(curl "${args[@]}" "${url}" || true)"
  if [[ "${http}" != "200" && "${http}" != "201" && "${http}" != "202" ]]; then
    echo "[ERROR] ${label} submission returned HTTP ${http}"
    cat "${response}" || true
    return 1
  fi
  local id
  id="$("${SYSTEM_PYTHON_BIN}" - "${response}" <<'PY'
import json
import sys
try:
    with open(sys.argv[1]) as handle:
        data = json.load(handle)
except Exception:
    print("")
    raise SystemExit(0)
print(data.get("id", ""))
PY
  )"
  poll_command "${id}" "${label}"
}

urlencode() {
  "${SYSTEM_PYTHON_BIN}" - "$1" <<'PY'
import sys
try:
    from urllib.parse import quote
except ImportError:
    from urllib import quote
print(quote(sys.argv[1], safe=""))
PY
}

echo "[INFO] Restarting Cloudera Manager server"
systemctl restart "${CM_SERVER_SERVICE}"
wait_for_cm_https

echo "[INFO] Restarting Cloudera Manager agents"
SSH_OPTS=(
  -p "${AUTO_TLS_SSH_PORT}"
  -i "${AUTO_TLS_SSH_KEY_FILE}"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o "ConnectTimeout=${AUTO_TLS_SSH_CONNECT_TIMEOUT_SECONDS}"
)
while read -r host; do
  [[ -z "${host}" ]] && continue
  if is_local_host "${host}"; then
    systemctl restart "${CM_AGENT_SERVICE}"
    echo "[OK] Restarted local agent on ${host}"
  else
    "${AUTO_TLS_SSH_BIN}" "${SSH_OPTS[@]}" "${AUTO_TLS_SSH_USER}@${host}" \
      "sudo -n systemctl restart ${CM_AGENT_SERVICE}"
    echo "[OK] Restarted remote agent on ${host}"
  fi
done < <(read_host_ids)

sleep 10
wait_for_cm_https

if [[ "${AUTO_TLS_POST_RESTART_MANAGEMENT_SERVICE}" == "true" ]]; then
  submit_post_command "${HTTPS_BASE}/cm/service/commands/restart" "Restart Cloudera Management Service"
fi

CLUSTERS_FILE="${AUTO_TLS_PAYLOAD_DIR}/clusters.json"
curl "${curl_args[@]}" -u "${AUTO_TLS_CM_USER}:${AUTO_TLS_CM_PASSWORD}" \
  -o "${CLUSTERS_FILE}" "${HTTPS_BASE}/clusters"
mapfile -t CLUSTERS < <("${SYSTEM_PYTHON_BIN}" - "${CLUSTERS_FILE}" <<'PY'
import json
import sys
with open(sys.argv[1]) as handle:
    data = json.load(handle)
for item in data.get("items", []):
    name = item.get("name")
    if name:
        print(name)
PY
)

for cluster in "${CLUSTERS[@]}"; do
  encoded="$(urlencode "${cluster}")"
  if [[ "${AUTO_TLS_POST_DEPLOY_CLIENT_CONFIG}" == "true" ]]; then
    if ! submit_post_command "${HTTPS_BASE}/clusters/${encoded}/commands/deployClientConfig" \
      "Deploy client configuration ${cluster}"; then
      echo "[WARN] Client configuration deployment was not accepted for ${cluster}; review stale configuration in CM"
    fi
  fi
  if [[ "${AUTO_TLS_POST_RESTART_CLUSTERS}" == "true" ]]; then
    submit_post_command "${HTTPS_BASE}/clusters/${encoded}/commands/restart" \
      "Restart cluster ${cluster}" '{}'
  fi
done

echo "[OK] Post-Auto-TLS restart workflow completed"
echo "[INFO] Cloudera Manager: ${CM_HTTPS_SCHEME}://${AUTO_TLS_CM_HOST}:${AUTO_TLS_CM_HTTPS_PORT}"
