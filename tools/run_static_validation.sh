#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo '==== Bash syntax ===='
while IFS= read -r file; do
  bash -n "$file"
  echo "[OK] ${file}"
done < <(find . -type f \( -name '*.sh' -o -name 'RUN_MANAGER' -o -name 'RUN_AGENT' -o -name 'EXPORTS' \) | sort)

# shellcheck disable=SC1091
source ./EXPORTS

echo '==== Required configuration ===='
required_variables=(
  CM_DB_PASS RM_DB_PASS REG_DB_PASS HUE_DB_PASS HIVE_DB_PASS RANGER_DB_PASS
  NIFI_SENSITIVE_PROPS_KEY CM_ADMIN_USER CM_ADMIN_PASSWORD
  CM_VERSION CM_REPO_BASE_URL CDP_RUNTIME_VERSION CFM_VERSION CFM_PARCEL_REPO_URL
  CFM_NIFI_CSD_JAR CFM_NIFIREGISTRY_CSD_JAR CFM_PARCEL_DIR_NAME
  PGDG_GPG_KEY_URL PGDG_REPO_RPM_URL JAVA_HOME_TARGET PG_SERVICE_NAME
)
for variable_name in "${required_variables[@]}"; do
  [[ -n "${!variable_name:-}" ]] || { echo "[ERROR] Required variable is empty: ${variable_name}"; exit 1; }
  echo "[OK] ${variable_name} is defined"
done

expected_cm_repo="${CLOUDERA_ARCHIVE_BASE_URL}/${CM_MAJOR_REPO}/${CM_VERSION}/${CM_OS_REPO}/yum/"
expected_cfm_repo="${CLOUDERA_ARCHIVE_BASE_URL}/${CFM_STREAM}/${CFM_VERSION}/${CFM_OS_REPO}/yum/tars/parcel/"
expected_nifi_csd="NIFI-${NIFI_VERSION}.${CFM_VERSION}-${CFM_BUILD}.jar"
expected_registry_csd="NIFIREGISTRY-${NIFI_REGISTRY_VERSION}.${CFM_VERSION}-${CFM_BUILD}.jar"
expected_parcel="CFM-${CFM_VERSION}-${CFM_BUILD}"

[[ "${CM_REPO_BASE_URL}" == "${expected_cm_repo}" ]] || { echo '[ERROR] CM_REPO_BASE_URL derivation mismatch'; exit 1; }
[[ "${CFM_PARCEL_REPO_URL}" == "${expected_cfm_repo}" ]] || { echo '[ERROR] CFM_PARCEL_REPO_URL derivation mismatch'; exit 1; }
[[ "${CFM_NIFI_CSD_JAR}" == "${expected_nifi_csd}" ]] || { echo '[ERROR] CFM_NIFI_CSD_JAR derivation mismatch'; exit 1; }
[[ "${CFM_NIFIREGISTRY_CSD_JAR}" == "${expected_registry_csd}" ]] || { echo '[ERROR] CFM_NIFIREGISTRY_CSD_JAR derivation mismatch'; exit 1; }
[[ "${CFM_PARCEL_DIR_NAME}" == "${expected_parcel}" ]] || { echo '[ERROR] CFM_PARCEL_DIR_NAME derivation mismatch'; exit 1; }
echo '[OK] Product repository, CSD, and parcel values derive from EXPORTS inputs.'

echo '==== Configurability audit ===='
./tools/audit_configurability.sh

echo '[OK] Static validation passed.'
