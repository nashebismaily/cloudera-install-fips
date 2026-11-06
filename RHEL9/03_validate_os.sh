#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 03_validate_os
validate_platform
check_disabled() {
  local service="$1" enabled
  if service_exists "${service}"; then
    ! systemctl is-active --quiet "${service}" || { echo "[ERROR] ${service} remains active"; return 1; }
    enabled="$(systemctl is-enabled "${service}" 2>/dev/null || true)"
    [[ "${enabled}" == masked || "${enabled}" == disabled ]] || { echo "[ERROR] ${service} can still start on boot (${enabled})"; return 1; }
  fi
}
[[ "${DISABLE_FIREWALLD}" != true ]] || check_disabled "${FIREWALLD_SERVICE}"
[[ "${FAPOLICYD_MODE}" != disable ]] || check_disabled "${FAPOLICYD_SERVICE}"
if [[ "${SELINUX_MODE}" == disabled || "${SELINUX_MODE}" == permissive || "${DISABLE_SELINUX}" == true ]]; then
  [[ "$(getenforce)" != Enforcing ]] || { echo '[ERROR] SELinux remains enforcing'; exit 1; }
fi
if [[ "${DISABLE_THP}" == true && -f "${THP_ENABLED_FILE}" ]]; then
  [[ "$(cat "${THP_ENABLED_FILE}")" == *'[never]'* ]] || { echo '[ERROR] THP remains enabled'; exit 1; }
fi
[[ "$(sysctl -n vm.swappiness)" == "${VM_SWAPPINESS}" ]] || { echo '[ERROR] swappiness tuning did not take effect'; exit 1; }
systemctl is-active --quiet "${CHRONY_SERVICE}"
chronyc waitsync 30 0.5
echo '[OK] OS FIPS, requested service controls, THP, swappiness and time synchronization verified.'
