#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 14_install_cfm_fips_jars
validate_platform
require_artifact_lock
resolve_fips_jars
mode="${1:-all}"
[[ "${mode}" == all || "${mode}" == cdp || "${mode}" == cfm ]] || { echo 'Usage: 14_install_cfm_fips_jars.sh [all|cdp|cfm]'; exit 1; }
if [[ "${mode}" != cdp ]]; then
  [[ -L "${CFM_PARCEL_STATE_LINK}" && "$(readlink -f "${CFM_PARCEL_STATE_LINK}")" == "$(readlink -f "${CFM_PARCEL_ROOT}")" ]] || {
  echo "[ERROR] Activate the configured CFM parcel first: ${CFM_PARCEL_DIR_NAME}"; exit 1;
  }
fi
if [[ "${mode}" != cfm ]]; then
  [[ -L "${CDP_PARCEL_ROOT}" && "$(basename "$(readlink -f "${CDP_PARCEL_ROOT}")")" == "${CDP_PARCEL_DIR_NAME}" ]] || {
    echo '[ERROR] Activate the locked CDP SP1 parcel before staging its SASL library'; exit 1;
  }
fi
read -r -a cdp_destinations <<< "${CDP_SASL_DESTINATIONS}"
destinations=()
[[ "${mode}" == cdp ]] || destinations+=("${CFM_TOOLKIT_LIB_DIR}" "${CFM_REGISTRY_LIB_DIR}" "${CFM_NIFI_LIB_DIR}")
[[ "${mode}" == cfm ]] || destinations+=("${cdp_destinations[@]}")
for destination in "${destinations[@]}"; do
  [[ -d "${destination}" ]] || { echo "[ERROR] Missing activated parcel directory: ${destination}"; exit 1; }
done
copy_jar() {
  local jar="$1" destination="$2"
  # Retain displaced copies outside the parcel's classpath. Multiple versions of
  # the same provider/SASL library can otherwise be selected unpredictably.
  local family="${jar%%-[0-9]*}" old backup
  backup="${PARCEL_JAR_BACKUP_DIR}/$(basename "$(dirname "${destination}")")/$(date +%Y%m%d_%H%M%S_%N)"
  for old in "${destination}/${family}"-*.jar; do
    [[ -f "${old}" && "${old##*/}" != "${jar}" ]] || continue
    mkdir -p "${backup}"
    mv -- "${old}" "${backup}/"
  done
  install -o "${CFM_FIPS_JAR_OWNER%:*}" -g "${CFM_FIPS_JAR_OWNER#*:}" -m "${CFM_FIPS_JAR_MODE}" \
    "${FIPS_JAR_SOURCE_DIR}/${jar}" "${destination}/${jar}"
  cmp -s "${FIPS_JAR_SOURCE_DIR}/${jar}" "${destination}/${jar}"
  echo "[OK] ${destination}/${jar}"
}
if [[ "${mode}" != cdp ]]; then
for destination in "${CFM_TOOLKIT_LIB_DIR}" "${CFM_REGISTRY_LIB_DIR}" "${CFM_NIFI_LIB_DIR}"; do
  for jar in "${FIPS_CCJ_JAR}" "${FIPS_BCTLS_JAR}" "${FIPS_BCUTIL_JAR}"; do copy_jar "${jar}" "${destination}"; done
  restorecon -Rv "${destination}" 2>/dev/null || true
done
copy_jar "${FIPS_SASL_JAR}" "${CFM_NIFI_LIB_DIR}"
fi
if [[ "${mode}" != cfm ]]; then
  for destination in "${cdp_destinations[@]}"; do copy_jar "${FIPS_SASL_JAR}" "${destination}"; done
fi
echo '[OK] Approved libraries staged in CFM Toolkit, Registry, NiFi, and CDP Hadoop directories.'
echo '[NEXT] Generate/apply the JDK 21 and HTTP/FIPS service settings with step 16 before starting NiFi/Registry.'
