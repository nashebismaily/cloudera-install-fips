#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
log_init "12_start_cm_services"
need_root
validate_platform
ensure_java_default
validate_java_11
configure_java_fips_safelogic
configure_cm_server_fips_opts
install_required_agent_python
validate_cm_agent_python_wrapper

mkdir -p "$(dirname "${CM_SERVER_DEFAULTS_FILE}")"
touch "${CM_SERVER_DEFAULTS_FILE}"

# Keep the stable Java home explicit for the CM Server process.
if grep -Eq '^[[:space:]]*export[[:space:]]+JAVA_HOME=' "${CM_SERVER_DEFAULTS_FILE}"; then
  sed -i "s|^[[:space:]]*export[[:space:]]\+JAVA_HOME=.*|export JAVA_HOME='${JAVA_HOME_TARGET}'|" "${CM_SERVER_DEFAULTS_FILE}"
else
  echo "export JAVA_HOME='${JAVA_HOME_TARGET}'" >> "${CM_SERVER_DEFAULTS_FILE}"
fi

if grep -Eq '^[[:space:]]*export[[:space:]]+CMF_FF_PREVENT_HOST_HEADER_INJECTION=' "${CM_SERVER_DEFAULTS_FILE}"; then
  sed -i "s|^[[:space:]]*export[[:space:]]\+CMF_FF_PREVENT_HOST_HEADER_INJECTION=.*|export CMF_FF_PREVENT_HOST_HEADER_INJECTION=\"${CM_PREVENT_HOST_HEADER_INJECTION}\"|" "${CM_SERVER_DEFAULTS_FILE}"
else
  echo "export CMF_FF_PREVENT_HOST_HEADER_INJECTION=\"${CM_PREVENT_HOST_HEADER_INJECTION}\"" >> "${CM_SERVER_DEFAULTS_FILE}"
fi
normalize_legacy_java_home_files

echo "==== Starting Cloudera Manager Server ===="
systemctl daemon-reload
systemctl enable "${CM_SERVER_SERVICE}"
systemctl restart "${CM_SERVER_SERVICE}"

echo "==== Waiting for CM on ${CM_HTTP_SCHEME}://${LOCALHOST_NAME}:${CM_HTTP_PORT} ===="
READY='false'
for ((attempt=1; attempt<=CM_WAIT_ATTEMPTS; attempt++)); do
  if ss -plnt | grep -q ":${CM_HTTP_PORT}"; then
    READY='true'
    break
  fi
  echo "Waiting for CM startup ${attempt}/${CM_WAIT_ATTEMPTS}"
  sleep "${CM_WAIT_INTERVAL_SECONDS}"
done
if [[ "${READY}" != 'true' ]]; then
  echo "[ERROR] CM did not listen on ${CM_HTTP_PORT}. Check ${CM_SERVER_LOG_FILE}"
  exit 1
fi

echo "==== Starting local CM agent services on the CM Server host ===="
systemctl enable "${CM_SUPERVISORD_SERVICE}" "${CM_AGENT_SERVICE}"
systemctl reset-failed "${CM_SUPERVISORD_SERVICE}" "${CM_AGENT_SERVICE}" || true
systemctl restart "${CM_SUPERVISORD_SERVICE}"
systemctl restart "${CM_AGENT_SERVICE}"
sleep "${SERVICE_SETTLE_SECONDS}"

for service_name in "${CM_SERVER_SERVICE}" "${CM_SUPERVISORD_SERVICE}" "${CM_AGENT_SERVICE}"; do
  systemctl status "${service_name}" --no-pager
  if ! systemctl is-active --quiet "${service_name}"; then
    echo "[ERROR] ${service_name} is not active."
    journalctl -u "${service_name}" -n "${CM_SERVER_JOURNAL_LINES}" --no-pager || true
    exit 1
  fi
done

local_url="${CM_HTTP_SCHEME}://${LOCALHOST_NAME}:${CM_HTTP_PORT}"
if curl_head_public "${local_url}"; then
  echo "[OK] CM responds locally: ${local_url}"
else
  echo "[ERROR] CM is listening but did not respond locally: ${local_url}"
  exit 1
fi

PRIVATE_IP="$(hostname -I | awk '{print $1}')"
DISPLAY_HOST="${CM_EXTERNAL_ACCESS_HOST:-${PRIVATE_IP}}"
echo "[OK] CM local services are healthy."
echo "[INFO] Browser URL: ${CM_HTTP_SCHEME}://${DISPLAY_HOST}:${CM_HTTP_PORT}"
echo "[INFO] Default login: ${CM_ADMIN_USER} / ${CM_ADMIN_PASSWORD}"
echo "[INFO] If local curl works but the browser cannot connect, verify routing, security groups, VPN/bastion access, and host firewall rules."
