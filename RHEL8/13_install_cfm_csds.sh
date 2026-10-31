#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
log_init "13_install_cfm_csds"
need_root
validate_platform
require_cloudera_credentials

mkdir -p "${CFM_CSD_DIR}" "${CFM_CSD_TMP_DIR}"
echo "==== CFM CSD configuration ===="
echo "CFM_VERSION=${CFM_VERSION}"
echo "CFM parcel repo=${CFM_PARCEL_REPO_URL}"
echo "NiFi CSD=${CFM_NIFI_CSD_URL}"
echo "NiFi Registry CSD=${CFM_NIFIREGISTRY_CSD_URL}"

cd "${CFM_CSD_TMP_DIR}"
rm -f ./*.jar
curl_download_auth "${CFM_NIFI_CSD_URL}" "${CFM_NIFI_CSD_JAR}"
curl_download_auth "${CFM_NIFIREGISTRY_CSD_URL}" "${CFM_NIFIREGISTRY_CSD_JAR}"

for file_name in "${CFM_NIFI_CSD_JAR}" "${CFM_NIFIREGISTRY_CSD_JAR}"; do
  size="$(stat -c%s "${file_name}")"
  if [[ "${size}" -lt "${CFM_CSD_MIN_BYTES}" ]]; then
    echo "[ERROR] Downloaded file is too small: ${file_name} (${size} bytes)"
    head -20 "${file_name}" || true
    exit 1
  fi
  echo "[OK] ${file_name} (${size} bytes)"
done

rm -f "${CFM_CSD_DIR}"/${CFM_NIFI_CSD_GLOB} "${CFM_CSD_DIR}"/${CFM_NIFIREGISTRY_CSD_GLOB}
cp -f "${CFM_CSD_TMP_DIR}"/*.jar "${CFM_CSD_DIR}/"
chown "${CFM_CSD_OWNER}" "${CFM_CSD_DIR}"/*.jar
chmod "${CFM_CSD_MODE}" "${CFM_CSD_DIR}"/*.jar
ls -lh "${CFM_CSD_DIR}" | grep -E 'NIFI|NIFIREGISTRY' || true

if systemctl is-active --quiet "${CM_SERVER_SERVICE}"; then
  echo "==== Restarting Cloudera Manager Server to load CSDs ===="
  systemctl restart "${CM_SERVER_SERVICE}"
  ready='false'
  for ((attempt=1; attempt<=CM_WAIT_ATTEMPTS; attempt++)); do
    if ss -plnt | grep -q ":${CM_HTTP_PORT}"; then
      ready='true'
      break
    fi
    echo "Waiting for CM restart ${attempt}/${CM_WAIT_ATTEMPTS}"
    sleep "${CM_WAIT_INTERVAL_SECONDS}"
  done
  if [[ "${ready}" != 'true' ]]; then
    echo "[ERROR] CM did not return on port ${CM_HTTP_PORT} after loading CSDs."
    echo "[INFO] Check ${CM_SERVER_LOG_FILE}"
    exit 1
  fi
  local_url="${CM_HTTP_SCHEME}://${LOCALHOST_NAME}:${CM_HTTP_PORT}"
  curl_head_public "${local_url}" || {
    echo "[ERROR] CM is listening but did not respond locally after the CSD restart: ${local_url}"
    exit 1
  }
  echo "[OK] CM returned and responds locally after loading CSDs: ${local_url}"
else
  echo "[INFO] CM server is not running; CSDs will load when it starts."
fi

cat <<EOFMSG

[OK] CFM CSDs installed.
Next in Cloudera Manager:
  1. Add CFM parcel repository: ${CFM_PARCEL_REPO_URL}
  2. Download, distribute, and activate the CFM parcel.
  3. Deploy CDP Runtime ${CDP_RUNTIME_VERSION} services first, including ZooKeeper.
  4. Deploy NiFi and NiFi Registry after the CFM parcel is active.

EOFMSG
