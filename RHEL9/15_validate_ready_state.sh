#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 15_validate_ready_state
stage="${1:-bootstrap}"
[[ "${stage}" == bootstrap || "${stage}" == deployed ]] || { echo 'Usage: 15_validate_ready_state.sh [bootstrap|deployed]'; exit 1; }
FAILURES=0
check() {
  local label="$1"; shift
  if "$@"; then echo "[OK] ${label}"; else echo "[ERROR] ${label}"; FAILURES=$((FAILURES+1)); fi
}
check 'Platform/FIPS policy' validate_platform
check 'CM JDK' validate_cm_java
check 'CFM JDK' validate_cfm_java
check 'Agent Python wrapper' validate_cm_agent_python_wrapper
check 'Optional Hue psycopg2' validate_hue_fips_psycopg2
check 'Both JDKs: providers, BCFKS, AES-GCM, service-user access' validate_java_fips_providers
for service in "${CM_AGENT_SERVICE}" "${CM_SUPERVISORD_SERVICE}"; do
  check "${service} active" systemctl is-active --quiet "${service}"
done
if service_exists "${CM_SERVER_SERVICE}"; then
  check 'CM server active' systemctl is-active --quiet "${CM_SERVER_SERVICE}"
  url="${CM_RUNTIME_PROTOCOL}://${MANAGER_HOST:-${LOCALHOST_NAME}}:${CM_RUNTIME_PORT}"
  args=(--fail --silent --show-error --location --connect-timeout "${CURL_CONNECT_TIMEOUT_SECONDS}" --max-time "${CURL_HEAD_MAX_TIME_SECONDS}")
  [[ -z "${CM_RUNTIME_CA_FILE}" ]] || args+=(--cacert "${CM_RUNTIME_CA_FILE}")
  check 'CM HTTP/HTTPS response' curl "${args[@]}" --output /dev/null "${url}"
  if [[ "${POSTGRES_INSTALL_MODE}" == local ]]; then check 'PostgreSQL active' systemctl is-active --quiet "${PG_SERVICE_NAME}"; fi
  if [[ -x "${PG_BIN_DIR}/psql" ]]; then
    check 'PostgreSQL TLS and hostname verification' env PGSSLMODE="${DB_SSLMODE}" PGSSLROOTCERT="${DB_CLIENT_CA_FILE}" \
      PGPASSWORD="${CM_DB_PASS}" "${PG_BIN_DIR}/psql" -h "${DB_HOST}" -p "${DB_PORT}" \
      -U "${CM_DB_USER}" -d "${CM_DB_NAME}" -v ON_ERROR_STOP=1 \
      -c 'SELECT ssl, version, cipher FROM pg_stat_ssl WHERE pid=pg_backend_pid();'
  fi
fi
if [[ "${stage}" == deployed ]]; then
  check 'Approved FIPS source artifacts' resolve_fips_jars
  if [[ -n "${FIPS_SASL_JAR}" ]]; then
    for directory in "${CFM_TOOLKIT_LIB_DIR}" "${CFM_REGISTRY_LIB_DIR}" "${CFM_NIFI_LIB_DIR}"; do
      for jar in "${FIPS_CCJ_JAR}" "${FIPS_BCTLS_JAR}" "${FIPS_BCUTIL_JAR}"; do
        check "Parcel jar ${directory}/${jar}" cmp -s "${FIPS_JAR_SOURCE_DIR}/${jar}" "${directory}/${jar}"
      done
    done
    read -r -a cdp_destinations <<< "${CDP_SASL_DESTINATIONS}"
    for directory in "${CFM_NIFI_LIB_DIR}" "${cdp_destinations[@]}"; do
      check "SASL jar ${directory}" cmp -s "${FIPS_JAR_SOURCE_DIR}/${FIPS_SASL_JAR}" "${directory}/${FIPS_SASL_JAR}"
    done
  fi
  echo '[MANUAL] Verify CM reports healthy NiFi/Registry roles, Java 21 process paths, effective BCFKS stores, and successful UI/cluster TLS handshakes.'
else
  echo '[INFO] Bootstrap checks exclude parcels and service-level TLS. Continue with Runtime/ZooKeeper, CFM activation, step 14, Auto-TLS, and step 16.'
fi
[[ "${FAILURES}" -eq 0 ]] || { echo "[ERROR] ${FAILURES} readiness checks failed"; exit 1; }
echo '[OK] Ready-state validation passed.'
