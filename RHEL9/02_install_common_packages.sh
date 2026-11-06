#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
log_init "02_install_common_packages"
need_root
validate_platform

read -r -a packages <<< "${COMMON_PACKAGES}"
FAILED=()
for package_name in "${packages[@]}"; do
  echo "---- Installing ${package_name}"
  if ! dnf install -y "${package_name}"; then
    echo "[WARN] Failed to install ${package_name}"
    FAILED+=("${package_name}")
  fi
done

for service_name in "${CHRONY_SERVICE}" "${RNG_SERVICE}"; do
  if service_exists "${service_name}"; then
    systemctl enable "${service_name}" || true
    systemctl restart "${service_name}" || true
  fi
done

echo
echo "System Python: $(${SYSTEM_PYTHON_BIN} --version 2>/dev/null || echo missing)"
echo "CM Agent Python: $(${CM_AGENT_PYTHON_BIN} --version 2>/dev/null || echo missing)"
install_required_agent_python
install_hue_fips_psycopg2
command -v nc || true
command -v jq || true

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "[ERROR] Failed packages: ${FAILED[*]}"
  exit 1
fi

echo "[OK] Common packages installed"
