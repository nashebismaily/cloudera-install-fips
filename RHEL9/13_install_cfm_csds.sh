#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 13_install_cfm_csds
validate_platform
require_artifact_lock
# Validate BOTH artifacts before replacing any installed descriptor. Other CSDs
# remain untouched; old NiFi descriptors are backed up outside the load directory.
"${BOOTSTRAP_PYTHON_BIN}" - "${ARTIFACT_LOCK_FILE}" "${ARTIFACT_CACHE_DIR}" <<'PYVERIFY'
import hashlib, json, sys, zipfile
from pathlib import Path
lock=json.loads(Path(sys.argv[1]).read_text())
for name, expected in lock['csds'].items():
    path=Path(sys.argv[2])/name
    if hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
        raise SystemExit('Cached CSD checksum mismatch: '+name)
    with zipfile.ZipFile(path) as jar:
        if jar.testzip() is not None or 'descriptor/service.sdl' not in jar.namelist():
            raise SystemExit('Invalid cached CSD: '+name)
PYVERIFY
install -d -m 0755 -o "${CLOUDERA_SERVICE_USER}" -g "${CLOUDERA_SERVICE_GROUP}" "${CFM_CSD_DIR}"
backup="${CSD_BACKUP_DIR}/$(date +%Y%m%d_%H%M%S_%N)"
for old in "${CFM_CSD_DIR}"/NIFI-*.jar "${CFM_CSD_DIR}"/NIFIREGISTRY-*.jar; do
  [[ -f "${old}" ]] || continue
  if [[ "${old##*/}" != "${CFM_NIFI_CSD_JAR}" && "${old##*/}" != "${CFM_NIFIREGISTRY_CSD_JAR}" ]]; then
    mkdir -p "${backup}"
    mv -- "${old}" "${backup}/"
  fi
done
for name in "${CFM_NIFI_CSD_JAR}" "${CFM_NIFIREGISTRY_CSD_JAR}"; do
  install -m "${CFM_CSD_MODE}" -o "${CLOUDERA_SERVICE_USER}" -g "${CLOUDERA_SERVICE_GROUP}" \
    "${ARTIFACT_CACHE_DIR}/${name}" "${CFM_CSD_DIR}/${name}"
  echo "[OK] Installed matching CSD: ${name}"
done
if systemctl is-active --quiet "${CM_SERVER_SERVICE}"; then
  systemctl restart "${CM_SERVER_SERVICE}"
  wait_for_cm
fi
echo "[OK] CFM CSDs installed. Activate the locked parcels shown in ${ARTIFACT_LOCK_FILE}, then run step 14 on every parcel host before starting services."
