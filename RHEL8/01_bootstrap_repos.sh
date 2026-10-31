#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
log_init "01_bootstrap_repos"
need_root
validate_platform

if [[ "${ALLOW_EXTERNAL}" != "true" ]]; then
  echo "[INFO] ALLOW_EXTERNAL=false. Current repositories only:"
  dnf repolist || true
  exit 0
fi

dnf clean all || true

if [[ "${ENABLE_CODEREADY}" == "true" ]]; then
  echo "==== Enabling CodeReady Builder if present ===="
  if dnf repolist all | grep -q "^${CODEREADY_REPO_ID}"; then
    dnf config-manager --set-enabled "${CODEREADY_REPO_ID}"
    echo "[OK] Enabled ${CODEREADY_REPO_ID}"
  else
    CRB_REPO="$(dnf repolist all | awk -v pattern="${CODEREADY_REPO_PATTERN}" '$1 ~ pattern {print $1; exit}')"
    if [[ -n "${CRB_REPO}" ]]; then
      dnf config-manager --set-enabled "${CRB_REPO}"
      echo "[OK] Enabled ${CRB_REPO}"
    else
      echo "[WARN] CodeReady Builder repository not found. PostgreSQL development dependencies may be unavailable."
    fi
  fi
else
  echo "[INFO] CodeReady Builder disabled by configuration"
fi

if [[ "${ENABLE_EPEL}" == "true" ]]; then
  echo "==== Installing EPEL repository ===="
  dnf install -y "${EPEL_RELEASE_RPM_URL}"
else
  echo "[INFO] EPEL disabled by configuration"
fi

if [[ "${ENABLE_PGDG}" == "true" ]]; then
  echo "==== Installing PGDG repository ===="
  # Live-install fix: import the PGDG signing key before installing the repo RPM.
  rpm --import "${PGDG_GPG_KEY_URL}"
  dnf install -y "${PGDG_REPO_RPM_URL}"
  if [[ "${DISABLE_OS_POSTGRES_MODULE}" == "true" ]]; then
    dnf -qy module disable "${POSTGRES_OS_MODULE_NAME}" || true
  fi
else
  echo "[INFO] PGDG disabled by configuration"
fi

dnf makecache || true
dnf repolist || true

echo "[OK] Repository bootstrap complete"
