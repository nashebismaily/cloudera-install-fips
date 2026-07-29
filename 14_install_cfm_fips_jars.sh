#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
log_init "14_install_cfm_fips_jars"
need_root
validate_platform

[[ -d "${FIPS_JAR_SOURCE_DIR}" ]] || {
  echo "[ERROR] FIPS_JAR_SOURCE_DIR does not exist: ${FIPS_JAR_SOURCE_DIR}"
  exit 1
}
[[ -d "${CFM_TOOLKIT_LIB_DIR}" ]] || {
  echo "[ERROR] CFM toolkit lib directory does not exist: ${CFM_TOOLKIT_LIB_DIR}"
  echo "[INFO] Activate parcel ${CFM_PARCEL_DIR_NAME} before running this script."
  exit 1
}

JARS=("${FIPS_BCTLS_JAR}" "${FIPS_CCJ_JAR}")
if [[ -n "${FIPS_EXTRA_JARS}" ]]; then
  read -r -a extra_jars <<< "${FIPS_EXTRA_JARS}"
  JARS+=("${extra_jars[@]}")
fi

echo "==== Copying SafeLogic/Bouncy Castle FIPS jars ===="
echo "Source: ${FIPS_JAR_SOURCE_DIR}"
echo "Destination: ${CFM_TOOLKIT_LIB_DIR}"
for jar in "${JARS[@]}"; do
  [[ -f "${FIPS_JAR_SOURCE_DIR}/${jar}" ]] || {
    echo "[ERROR] Missing jar: ${FIPS_JAR_SOURCE_DIR}/${jar}"
    ls -lh "${FIPS_JAR_SOURCE_DIR}" || true
    exit 1
  }
  cp -af "${FIPS_JAR_SOURCE_DIR}/${jar}" "${CFM_TOOLKIT_LIB_DIR}/"
  chown "${CFM_FIPS_JAR_OWNER}" "${CFM_TOOLKIT_LIB_DIR}/${jar}"
  chmod "${CFM_FIPS_JAR_MODE}" "${CFM_TOOLKIT_LIB_DIR}/${jar}"
  echo "[OK] Copied ${jar}"
done
restorecon -Rv "${CFM_TOOLKIT_LIB_DIR}" 2>/dev/null || true
ls -lh "${CFM_TOOLKIT_LIB_DIR}" | grep -E "$(printf '%s|' "${JARS[@]}" | sed 's/|$//')" || true

cat <<EOFMSG

[OK] CFM FIPS jars copied.
Use the configured FIPS-compatible keystore/truststore and bootstrap settings when TLS is enabled for NiFi and NiFi Registry.

EOFMSG
