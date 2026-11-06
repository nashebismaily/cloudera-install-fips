#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
echo '==== Shell syntax ===='
count=0
while IFS= read -r -d '' file; do
  bash -n "${file}"
  count=$((count+1))
done < <(find . -type f \( -name '*.sh' -o -name RUN_MANAGER -o -name RUN_AGENT -o -name EXPORTS \) -print0)
echo "[OK] ${count} shell files"
python3 tools/validate_sources.py
source ./EXPORTS
required=(CM_VERSION CFM_VERSION NIFI_VERSION CDP_RUNTIME_VERSION CFM_PARCEL_REPO_URL
  CM_REPO_BASE_URL JAVA_HOME_TARGET CFM_JAVA_HOME CM_AGENT_PYTHON_BIN FIPS_CCJ_JAR FIPS_BCTLS_JAR
  FIPS_BCUTIL_JAR FIPS_SASL_JAR_GLOB FIPS_CHECKSUM_FILE CDP_PARCEL_REPO_URL PG_SERVICE_NAME)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { echo "[ERROR] Missing profile setting: ${name}"; exit 1; }
done
[[ "${CFM_MANIFEST_URL}" == "${CFM_PARCEL_REPO_URL}manifest.json" ]]
[[ "${AUTO_TLS_STORE_TYPE}" == "${JAVA_FIPS_KEYSTORE_TYPE}" && "${POSTGRES_REQUIRE_TLS}" == true ]]
[[ "${RESET_CM_AGENT_IDENTITY}" == false ]]
echo '[OK] Profile inputs, derived CSD/parcel names, FIPS stores, PostgreSQL TLS, and safe agent reruns'
bash tools/audit_configurability.sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
echo '[OK] RHEL9 static validation and regression tests passed.'
