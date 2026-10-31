#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
log_init "03_configure_os"
need_root
validate_platform

echo "==== SELinux / firewalld / fapolicyd choices ===="
if [[ "${DISABLE_SELINUX}" == "true" ]]; then
  SELINUX_MODE='disabled'
fi
case "${SELINUX_MODE}" in
  disabled)
    if [[ -f "${SELINUX_CONFIG_FILE}" ]]; then
      sed -i 's/^SELINUX=.*/SELINUX=disabled/' "${SELINUX_CONFIG_FILE}"
    fi
    setenforce 0 2>/dev/null || true
    echo "[OK] SELinux set to disabled persistently; current mode: $(getenforce 2>/dev/null || echo unknown)"
    ;;
  permissive)
    if [[ -f "${SELINUX_CONFIG_FILE}" ]]; then
      sed -i 's/^SELINUX=.*/SELINUX=permissive/' "${SELINUX_CONFIG_FILE}"
    fi
    setenforce 0 2>/dev/null || true
    echo "[OK] SELinux set to permissive persistently"
    ;;
  unchanged)
    echo "[INFO] SELinux left unchanged: $(getenforce 2>/dev/null || echo unknown)"
    ;;
  *)
    echo "[ERROR] Invalid SELINUX_MODE=${SELINUX_MODE}. Use unchanged, permissive, or disabled."
    exit 1
    ;;
esac

if [[ "${DISABLE_FIREWALLD}" == "true" ]] && service_exists "${FIREWALLD_SERVICE}"; then
  systemctl stop "${FIREWALLD_SERVICE}" || true
  systemctl disable "${FIREWALLD_SERVICE}" || true
  echo "[OK] ${FIREWALLD_SERVICE} disabled"
else
  echo "[INFO] ${FIREWALLD_SERVICE} left unchanged. Network security groups and host firewalls must allow configured ports."
fi

if service_exists "${FAPOLICYD_SERVICE}"; then
  case "${FAPOLICYD_MODE}" in
    disable)
      systemctl stop "${FAPOLICYD_SERVICE}" || true
      systemctl disable "${FAPOLICYD_SERVICE}" || true
      systemctl mask "${FAPOLICYD_SERVICE}" || true
      echo "[OK] ${FAPOLICYD_SERVICE} stopped, disabled, and masked because it blocked SafeLogic jars during the live install"
      ;;
    warn)
      if systemctl is-active --quiet "${FAPOLICYD_SERVICE}"; then
        echo "[WARN] ${FAPOLICYD_SERVICE} is active and may block Java from loading ${JAVA_FIPS_DIR}/*.jar"
      fi
      ;;
    ignore)
      echo "[INFO] ${FAPOLICYD_SERVICE} left unchanged"
      ;;
    *)
      echo "[ERROR] Invalid FAPOLICYD_MODE=${FAPOLICYD_MODE}. Use disable, warn, or ignore."
      exit 1
      ;;
  esac
fi

if [[ "${DISABLE_THP}" == "true" ]]; then
  cat >"${THP_SERVICE_FILE}" <<EOFTHP
[Unit]
Description=Disable Transparent Huge Pages
After=network.target

[Service]
Type=oneshot
ExecStart=${BASH_BIN} -c 'if [ -f ${THP_ENABLED_FILE} ]; then echo never > ${THP_ENABLED_FILE}; fi; if [ -f ${THP_DEFRAG_FILE} ]; then echo never > ${THP_DEFRAG_FILE}; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOFTHP
  systemctl daemon-reload
  systemctl enable "${THP_SERVICE_NAME}"
  systemctl restart "${THP_SERVICE_NAME}" || true
fi

cat >"${CLOUDERA_SYSCTL_FILE}" <<EOFSYSCTL
vm.swappiness=${VM_SWAPPINESS}
fs.file-max=${FS_FILE_MAX}
vm.max_map_count=${VM_MAX_MAP_COUNT}
net.core.somaxconn=${NET_CORE_SOMAXCONN}
EOFSYSCTL
sysctl --system || true

mkdir -p "${CLOUDERA_SYSTEMD_LIMITS_DIR}" "${CLOUDERA_SECURITY_LIMITS_DIR}"
cat >"${CLOUDERA_SYSTEMD_LIMITS_FILE}" <<EOFLIMITS
[Manager]
DefaultLimitNOFILE=${DEFAULT_NOFILE_LIMIT}
DefaultLimitNPROC=${DEFAULT_NPROC_LIMIT}
EOFLIMITS
cat >"${CLOUDERA_SECURITY_LIMITS_FILE}" <<EOFLIMITS
* soft nofile ${DEFAULT_NOFILE_LIMIT}
* hard nofile ${DEFAULT_NOFILE_LIMIT}
* soft nproc ${DEFAULT_NPROC_LIMIT}
* hard nproc ${DEFAULT_NPROC_LIMIT}
${CLOUDERA_SERVICE_USER} soft nofile ${DEFAULT_NOFILE_LIMIT}
${CLOUDERA_SERVICE_USER} hard nofile ${DEFAULT_NOFILE_LIMIT}
${CLOUDERA_SERVICE_USER} soft nproc ${DEFAULT_NPROC_LIMIT}
${CLOUDERA_SERVICE_USER} hard nproc ${DEFAULT_NPROC_LIMIT}
EOFLIMITS
systemctl daemon-reexec || true

echo "THP: $(cat "${THP_ENABLED_FILE}" 2>/dev/null || echo unknown)"
sysctl vm.swappiness || true
ulimit -n || true

echo "[OK] OS configuration complete"
