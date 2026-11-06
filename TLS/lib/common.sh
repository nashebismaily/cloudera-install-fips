#!/usr/bin/env bash
# Standalone add-on helpers. No RHEL9 scripts or configuration are imported.
set -euo pipefail
TLS_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${TLS_MODULE_DIR}/lib.sh"
need_root() { [[ "${EUID}" -eq 0 ]] || fail 'Run as root'; }
log_init() { umask 077; mkdir -p "${LOG_DIR}"; exec > >(tee -a "${LOG_DIR}/$1_$(date +%Y%m%d_%H%M%S).log") 2>&1; }
validate_platform() {
  [[ "$(cat "${FIPS_KERNEL_FLAG_FILE}")" == 1 ]] || fail 'OS FIPS must be enabled'
  local policy; policy="$("${CRYPTO_POLICY_COMMAND}" --show)"
  [[ "${policy}" == "${FIPS_CRYPTO_POLICY}" || "${policy}" == "${FIPS_CRYPTO_POLICY}:"* ]] || fail 'Expected FIPS crypto policy'
}
timestamped_backup() { [[ ! -f "$1" ]] || cp -a -- "$1" "$1.bak.$(date +%Y%m%d_%H%M%S_%N)"; }
ensure_java_default() { export JAVA_HOME="${JAVA_HOME_TARGET}"; export PATH="${JAVA_HOME}/bin:${PATH}"; export JDK_JAVA_OPTIONS="${AUTO_TLS_JAVA_OPTIONS}"; }
prepare_database_truststore() {
  local temp opts=() inputs=()
  temp="$(mktemp -d)";read -r -a opts <<< "${AUTO_TLS_JAVA_OPTIONS}"
  [[ "${1:-}" != require-cluster || -s "${CM_CLUSTER_CA_FILE}" ]] || fail 'Stage the issued cluster CA'
  [[ ! -s "${CM_CLUSTER_CA_FILE}" ]] || inputs+=("${CM_CLUSTER_CA_FILE}")
  if [[ "${DB_SSLMODE}" != disable ]]; then
    [[ -s "${DB_CLIENT_CA_FILE}" ]] || fail 'Stage the database CA for the explicitly selected database TLS action'
    inputs+=("${DB_CLIENT_CA_FILE}")
  fi
  [[ -z "${JAVA_EXTRA_TRUST_CA_FILE}" ]] || inputs+=("${JAVA_EXTRA_TRUST_CA_FILE}")
  if ! env -u JDK_JAVA_OPTIONS "${JAVA_HOME_TARGET}/bin/java" "${opts[@]}" \
      "${TLS_MODULE_DIR}/lib/TruststoreTool.java" "${temp}/roots.bcfks" "${inputs[@]}"; then
    rm -rf -- "${temp}";return 1
  fi
  install -o root -g root -m 0644 "${temp}/roots.bcfks" "${DB_JAVA_TRUSTSTORE}"
  rm -rf -- "${temp}"
  configure_optional_tls_defaults
}
configure_optional_tls_defaults() {
  [[ ${#DB_TRUSTSTORE_PASSWORD} -ge ${MIN_FIPS_PASSWORD_LENGTH} && "${DB_TRUSTSTORE_PASSWORD}" =~ ^[A-Za-z0-9]+$ ]] || fail 'Use an alphanumeric TLS runtime-store password of at least 14 characters'
  local options="${AUTO_TLS_JAVA_OPTIONS} -Djavax.net.ssl.trustStoreType=BCFKS -Djavax.net.ssl.trustStore=${DB_JAVA_TRUSTSTORE} -Djavax.net.ssl.trustStorePassword=${DB_TRUSTSTORE_PASSWORD}"
  if [[ -f "${CM_SERVER_DEFAULTS_FILE}" ]]; then
    timestamped_backup "${CM_SERVER_DEFAULTS_FILE}"
    local temp;temp="$(mktemp)"
    awk '/# BEGIN OPTIONAL TLS/{skip=1;next} /# END OPTIONAL TLS/{skip=0;next} !skip{print}' "${CM_SERVER_DEFAULTS_FILE}" > "${temp}"
    cat >> "${temp}" <<EOFTLS
# BEGIN OPTIONAL TLS
export CMF_JAVA_OPTS="\${CMF_JAVA_OPTS:-} -Dorg.bouncycastle.jsse.fips.allowGCMCiphers=true -Djavax.net.ssl.trustStoreType=BCFKS -Djavax.net.ssl.trustStore=${DB_JAVA_TRUSTSTORE} -Djavax.net.ssl.trustStorePassword=${DB_TRUSTSTORE_PASSWORD}"
# END OPTIONAL TLS
EOFTLS
    cat "${temp}" > "${CM_SERVER_DEFAULTS_FILE}";rm -f -- "${temp}"
    chmod 0640 "${CM_SERVER_DEFAULTS_FILE}"
  fi
  local directory
  for directory in "${CM_AGENT_SYSTEMD_TLS_DIR}" "${CM_SUPERVISORD_SYSTEMD_TLS_DIR}"; do
    mkdir -p "${directory}"
    printf '[Service]\nEnvironment="JDK_JAVA_OPTIONS=%s"\n' "${options}" > "${directory}/optional-tls.conf"
    chmod 0640 "${directory}/optional-tls.conf"
  done
}
