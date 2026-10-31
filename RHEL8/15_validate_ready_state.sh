#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
log_init "15_validate_ready_state"
need_root

FAILURES=0
fail_or_warn() {
  local message="$1"
  if [[ "${VALIDATION_STRICT}" == 'true' ]]; then
    echo "[ERROR] ${message}"
    FAILURES=$((FAILURES + 1))
  else
    echo "[WARN] ${message}"
  fi
}

validate_platform

echo "==== Python ===="
echo "System Python: $(${SYSTEM_PYTHON_BIN} --version 2>/dev/null || echo missing)"
echo "Required CM Agent Python: ${CM_AGENT_PYTHON_BIN}"
if [[ -x "${CM_AGENT_PYTHON_BIN}" ]]; then
  "${CM_AGENT_PYTHON_BIN}" --version || true
else
  fail_or_warn "Required CM Agent Python missing: ${CM_AGENT_PYTHON_BIN}"
fi
if [[ -e "${CM_AGENT_PYTHON_WRAPPER}" ]]; then
  validate_cm_agent_python_wrapper || fail_or_warn 'CM agent Python wrapper validation failed'
fi

echo
echo "==== Hue / psycopg2 FIPS readiness ===="
validate_hue_fips_psycopg2 || fail_or_warn 'Hue psycopg2 validation failed'

echo
echo "==== Java / SafeLogic ===="
if [[ "${JAVA_INSTALL_MODE}" != 'skip' ]]; then
  ensure_java_default || fail_or_warn 'Java default selection failed'
  validate_java_11 || fail_or_warn "Java ${JAVA_MAJOR} validation failed"
  if [[ "${CONFIGURE_JAVA_FIPS}" == 'true' ]]; then
    if [[ -d "${JAVA_FIPS_DIR}" ]]; then
      ls -ld "${JAVA_FIPS_DIR}"
      ls -lh "${JAVA_FIPS_DIR}" || true
      validate_java_fips_providers || fail_or_warn 'Java FIPS provider validation failed'
    else
      fail_or_warn "Java FIPS directory missing: ${JAVA_FIPS_DIR}"
    fi
  fi
fi

if service_exists "${FAPOLICYD_SERVICE}"; then
  echo "${FAPOLICYD_SERVICE} active: $(systemctl is-active "${FAPOLICYD_SERVICE}" 2>/dev/null || true)"
  echo "${FAPOLICYD_SERVICE} enabled: $(systemctl is-enabled "${FAPOLICYD_SERVICE}" 2>/dev/null || true)"
  if [[ "${FAPOLICYD_MODE}" == 'disable' ]] && systemctl is-active --quiet "${FAPOLICYD_SERVICE}"; then
    fail_or_warn "${FAPOLICYD_SERVICE} is active even though FAPOLICYD_MODE=disable"
  fi
fi

echo
echo "==== PostgreSQL ===="
if service_exists "${PG_SERVICE_NAME}"; then
  systemctl status "${PG_SERVICE_NAME}" --no-pager 2>/dev/null || true
  systemctl is-active --quiet "${PG_SERVICE_NAME}" || fail_or_warn "${PG_SERVICE_NAME} is installed but inactive"
  if [[ -x "${PG_BIN_DIR}/psql" ]] && id "${PG_OS_USER}" >/dev/null 2>&1; then
    runuser -u "${PG_OS_USER}" -- "${PG_BIN_DIR}/psql" -c 'SELECT version();' 2>/dev/null || fail_or_warn 'PostgreSQL query failed'
  fi
  ss -plnt | grep ":${DB_PORT}" || fail_or_warn "No listener detected on PostgreSQL port ${DB_PORT}"
else
  echo "[INFO] ${PG_SERVICE_NAME} is not installed on this host; skipping PostgreSQL checks."
fi

echo
echo "==== Cloudera Manager services ===="
for service_name in "${CM_SERVER_SERVICE}" "${CM_SUPERVISORD_SERVICE}" "${CM_AGENT_SERVICE}"; do
  if service_exists "${service_name}"; then
    systemctl status "${service_name}" --no-pager 2>/dev/null || true
    systemctl is-active --quiet "${service_name}" || fail_or_warn "${service_name} is installed but inactive"
  else
    echo "[INFO] ${service_name} is not installed on this host."
  fi
done

if service_exists "${CM_SERVER_SERVICE}"; then
  ss -plnt | grep ":${CM_HTTP_PORT}" || fail_or_warn "CM HTTP listener not detected on ${CM_HTTP_PORT}"
  local_url="${CM_HTTP_SCHEME}://${LOCALHOST_NAME}:${CM_HTTP_PORT}"
  if curl_head_public "${local_url}"; then
    echo "[OK] CM responds locally: ${local_url}"
  else
    fail_or_warn "CM does not respond locally at ${local_url}"
  fi
  if [[ -n "${CM_EXTERNAL_ACCESS_HOST}" ]]; then
    echo "[INFO] Expected browser URL: ${CM_HTTP_SCHEME}://${CM_EXTERNAL_ACCESS_HOST}:${CM_HTTP_PORT}"
  else
    echo "[INFO] CM is locally healthy. External browser access still depends on routing, security groups, VPN/bastion access, and firewall rules."
  fi
fi

echo
echo "==== CSDs ===="
if [[ -d "${CFM_CSD_DIR}" ]]; then
  ls -lh "${CFM_CSD_DIR}" | grep -E 'NIFI|NIFIREGISTRY' || true
else
  echo "[INFO] CSD directory is not present yet: ${CFM_CSD_DIR}"
fi

echo
echo "==== CFM parcel / FIPS jars ===="
echo "Expected CFM parcel root: ${CFM_PARCEL_ROOT}"
if [[ -d "${CFM_TOOLKIT_LIB_DIR}" ]]; then
  echo "[OK] Toolkit lib dir exists: ${CFM_TOOLKIT_LIB_DIR}"
  JARS=("${FIPS_BCTLS_JAR}" "${FIPS_CCJ_JAR}")
  if [[ -n "${FIPS_EXTRA_JARS}" ]]; then
    read -r -a extra_jars <<< "${FIPS_EXTRA_JARS}"
    JARS+=("${extra_jars[@]}")
  fi
  for jar in "${JARS[@]}"; do
    [[ -f "${CFM_TOOLKIT_LIB_DIR}/${jar}" ]] \
      && echo "[OK] Found ${CFM_TOOLKIT_LIB_DIR}/${jar}" \
      || fail_or_warn "Missing ${CFM_TOOLKIT_LIB_DIR}/${jar}"
  done
else
  if [[ "${CFM_TOOLKIT_MISSING_IS_WARNING}" == 'true' ]]; then
    echo "[WARN] CFM toolkit lib dir not found yet. This is expected before the CFM parcel is activated."
  else
    fail_or_warn "CFM toolkit lib dir not found: ${CFM_TOOLKIT_LIB_DIR}"
  fi
fi

echo
echo "==== Manual CM setup reminders ===="
cat <<EOFMSG
1. Deploy CDP Runtime ${CDP_RUNTIME_VERSION} services first. ZooKeeper comes from CDP Runtime.
2. Add CFM parcel repository: ${CFM_PARCEL_REPO_URL}
3. Download, distribute, and activate parcel ${CFM_PARCEL_DIR_NAME}.
4. Run 14_install_cfm_fips_jars.sh after the parcel is active on each applicable host.
5. Configure approved enterprise certificates or the optional Auto-TLS utility afterward.
6. Set NiFi sensitive properties algorithm to ${NIFI_SENSITIVE_PROPS_ALGORITHM}.
EOFMSG

if [[ ${FAILURES} -gt 0 ]]; then
  echo "[ERROR] Validation completed with ${FAILURES} failure(s)."
  exit 1
fi
echo "[OK] Validation complete"
