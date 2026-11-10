#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
MANAGER_ARG="${1:-${MANAGER_HOST}}"
log_init "10_configure_cm_agent"
need_root
validate_platform
ensure_java_default
validate_cm_java
configure_java_fips_safelogic
install_required_agent_python
validate_cm_agent_python_wrapper
install_host_inspector_python

if [[ -z "${MANAGER_ARG}" ]]; then
  echo "Usage: sudo -E bash 10_configure_cm_agent.sh <manager-fqdn-or-private-dns>"
  echo "Or set MANAGER_HOST in EXPORTS."
  exit 1
fi
[[ -f "${CM_AGENT_CONFIG_FILE}" ]] || { echo "[ERROR] Missing ${CM_AGENT_CONFIG_FILE}. Install the CM agent first."; exit 1; }

timestamped_backup "${CM_AGENT_CONFIG_FILE}"
"${SYSTEM_PYTHON_BIN}" "${SCRIPT_DIR}/lib/configure_agent.py" "${MANAGER_ARG}"

if [[ "${RESET_CM_AGENT_IDENTITY}" == "true" ]]; then
  read -r -a identity_files <<< "${CM_AGENT_IDENTITY_FILES}"
  for identity_file in "${identity_files[@]}"; do
    rm -rf "${CM_AGENT_STATE_DIR}/${identity_file}"
  done
fi

configure_agent_fips_environment
echo "==== Starting Cloudera Manager agent services ===="
systemctl daemon-reload
systemctl enable "${CM_SUPERVISORD_SERVICE}" "${CM_AGENT_SERVICE}"
systemctl reset-failed "${CM_SUPERVISORD_SERVICE}" "${CM_AGENT_SERVICE}" || true
systemctl restart "${CM_SUPERVISORD_SERVICE}"
systemctl restart "${CM_AGENT_SERVICE}"
sleep "${SERVICE_SETTLE_SECONDS}"

for service_name in "${CM_SUPERVISORD_SERVICE}" "${CM_AGENT_SERVICE}"; do
  systemctl status "${service_name}" --no-pager
  if ! systemctl is-active --quiet "${service_name}"; then
    echo "[ERROR] ${service_name} is not active."
    journalctl -u "${service_name}" -n "${CM_AGENT_JOURNAL_LINES}" --no-pager || true
    exit 1
  fi
done

# On a fresh manager, step 12 will register its Java home after CM starts.
if ! service_exists "${CM_SERVER_SERVICE}" || systemctl is-active --quiet "${CM_SERVER_SERVICE}"; then
  register_cm_host_java_home "${MANAGER_ARG}"
fi
echo "[OK] CM agent services are running and point to ${MANAGER_ARG}:${CM_AGENT_PORT}"
