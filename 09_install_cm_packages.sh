#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
ROLE="${1:-}"
log_init "09_install_cm_packages_${ROLE:-unknown}"
need_root
validate_platform
ensure_java_default
validate_java_11
install_required_agent_python

if [[ "${ROLE}" != 'manager' && "${ROLE}" != 'agent' ]]; then
  echo "Usage: sudo -E bash 09_install_cm_packages.sh manager|agent"
  exit 1
fi

if [[ "${ROLE}" == 'manager' ]]; then
  echo "==== Installing Cloudera Manager server and agent packages ===="
  read -r -a packages <<< "${CM_MANAGER_PACKAGES}"
else
  echo "==== Installing Cloudera Manager agent packages and PostgreSQL JDBC driver ===="
  read -r -a packages <<< "${CM_AGENT_PACKAGES}"
  read -r -a jdbc_packages <<< "${POSTGRES_JDBC_PACKAGE}"
  packages+=("${jdbc_packages[@]}")
fi
dnf install -y "${packages[@]}"
rpm -qa | grep -E "${CM_PACKAGE_QUERY_REGEX}" | sort || true
validate_cm_agent_python_wrapper
install_hue_fips_psycopg2

if [[ "${ROLE}" == 'agent' ]]; then
  # Installing the JDBC RPM can change the active Java alternative. Restore the
  # configured Java version and verify that the driver is available for a NiFi
  # Registry role placed on this host.
  ensure_java_default
  validate_java_11
  if ! compgen -G "${POSTGRES_JDBC_DIR}/${POSTGRES_JDBC_GLOB}" >/dev/null; then
    echo "[ERROR] PostgreSQL JDBC jar not found in ${POSTGRES_JDBC_DIR}."
    exit 1
  fi
  echo "[OK] PostgreSQL JDBC driver is available in ${POSTGRES_JDBC_DIR}."
fi

echo "[OK] CM packages installed for role=${ROLE}"
