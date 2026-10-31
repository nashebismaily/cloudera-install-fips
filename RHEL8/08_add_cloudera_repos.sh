#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
log_init "08_add_cloudera_repos"
need_root
validate_platform
require_cloudera_credentials

mkdir -p "$(dirname "${CM_REPO_FILE}")"
cat >"${CM_REPO_FILE}" <<EOFREPO
[${CM_REPO_ID}]
name=${CM_REPO_NAME}
baseurl=${CM_REPO_BASE_URL}
username=${CLOUDERA_REPO_USER}
password=${CLOUDERA_REPO_PASS}
enabled=${CM_REPO_ENABLED}
gpgcheck=${CM_REPO_GPGCHECK}
repo_gpgcheck=${CM_REPO_REPO_GPGCHECK}
sslverify=${CM_REPO_SSLVERIFY}
EOFREPO
if [[ -n "${CM_REPO_GPGKEY_URL}" ]]; then
  echo "gpgkey=${CM_REPO_GPGKEY_URL}" >> "${CM_REPO_FILE}"
fi
chmod 0600 "${CM_REPO_FILE}"

dnf clean all || true
dnf makecache --disablerepo='*' --enablerepo="${CM_REPO_ID}" || true
dnf repolist "${CM_REPO_ID}" || true

echo "[OK] Cloudera Manager repo configured: ${CM_REPO_BASE_URL}"
