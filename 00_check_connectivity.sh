#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
log_init "00_check_connectivity"

validate_platform

check_http() {
  local url="$1" name="$2"
  if curl_head_public "${url}"; then
    echo "[OK] ${name} reachable: ${url}"
  else
    echo "[WARN] ${name} not reachable: ${url}"
  fi
}

check_tcp() {
  local host="$1" port="$2" name="$3"
  if command -v nc >/dev/null 2>&1; then
    if nc -zw"${TCP_CONNECT_TIMEOUT_SECONDS}" "${host}" "${port}" >/dev/null 2>&1; then
      echo "[OK] ${name} reachable at ${host}:${port}"
    else
      echo "[WARN] ${name} not reachable at ${host}:${port}"
    fi
  else
    echo "[WARN] nc missing; skipping ${name} TCP check"
  fi
}

check_name() {
  local host="$1" name="$2"
  if getent ahosts "${host}" >/dev/null 2>&1; then
    echo "[OK] ${name} resolves: ${host}"
    getent ahosts "${host}" | head -3 || true
  else
    echo "[WARN] ${name} does not resolve: ${host}"
  fi
  if [[ "${PREFLIGHT_PING_HOSTS}" == "true" ]] && command -v ping >/dev/null 2>&1; then
    ping -c 1 -W "${TCP_CONNECT_TIMEOUT_SECONDS}" "${host}" >/dev/null 2>&1 \
      && echo "[OK] ${name} responds to ICMP: ${host}" \
      || echo "[WARN] ${name} did not respond to ICMP; this may be blocked by policy."
  fi
}

echo "==== Basic commands ===="
read -r -a commands <<< "${PREFLIGHT_COMMANDS}"
for command_name in "${commands[@]}"; do
  warn_cmd "${command_name}"
done

echo
echo "==== Identity / network ===="
hostname -f || true
hostname -I || true
ip route || true

echo
echo "==== FIPS detail ===="
cat "${FIPS_KERNEL_FLAG_FILE}" || true
fips-mode-setup --check || true

echo
echo "==== SELinux / firewalld / fapolicyd / time ===="
getenforce || true
systemctl is-active "${FIREWALLD_SERVICE}" 2>/dev/null || true
systemctl is-enabled "${FIREWALLD_SERVICE}" 2>/dev/null || true
systemctl is-active "${FAPOLICYD_SERVICE}" 2>/dev/null || true
systemctl is-enabled "${FAPOLICYD_SERVICE}" 2>/dev/null || true
timedatectl || true
chronyc tracking || true

echo
echo "==== DNF repos ===="
dnf repolist || true

echo
echo "==== Internet/repo reachability ===="
check_http "${REDHAT_CDN_URL}" "Red Hat CDN"
check_http "${PGDG_CONNECTIVITY_URL}" "PostgreSQL PGDG"
check_http "${CLOUDERA_CONNECTIVITY_URL}" "Cloudera archive"
if [[ "${ENABLE_EPEL}" == "true" ]]; then
  check_http "${EPEL_CONNECTIVITY_URL}" "EPEL"
fi

echo
echo "==== Cloudera protected repo checks ===="
if [[ -n "${CLOUDERA_REPO_USER}" && -n "${CLOUDERA_REPO_PASS}" ]]; then
  echo "CM repo: ${CM_REPO_BASE_URL}"
  curl_head_auth "${CM_REPO_BASE_URL}" \
    && echo "[OK] CM repo reachable with supplied credentials" \
    || echo "[WARN] CM repo not reachable with supplied credentials"
  echo "CFM parcel repo: ${CFM_PARCEL_REPO_URL}"
  curl_head_auth "${CFM_PARCEL_REPO_URL}" \
    && echo "[OK] CFM parcel repo reachable with supplied credentials" \
    || echo "[WARN] CFM parcel repo not reachable with supplied credentials"
else
  echo "[INFO] CLOUDERA_REPO_USER/PASS not set; skipping protected repo auth checks"
fi

echo
echo "==== East/west checks ===="
if [[ -n "${MANAGER_HOST}" ]]; then
  check_name "${MANAGER_HOST}" "Manager host"
  check_tcp "${MANAGER_HOST}" "${CM_HTTP_PORT}" "CM HTTP UI"
  check_tcp "${MANAGER_HOST}" "${CM_AGENT_PORT}" "CM agent heartbeat listener"
  check_tcp "${MANAGER_HOST}" "${DB_PORT}" "PostgreSQL"
fi
if [[ -n "${AGENT_HOST}" ]]; then
  check_name "${AGENT_HOST}" "Agent host"
  check_tcp "${AGENT_HOST}" "${AGENT_TCP_CHECK_PORT}" "Agent host management/SSH port"
  if [[ "${CHECK_ZOOKEEPER_PORT}" == "true" ]]; then
    check_tcp "${AGENT_HOST}" "${ZOOKEEPER_CLIENT_PORT}" "ZooKeeper client port"
  fi
fi

if [[ -n "${CM_EXTERNAL_ACCESS_HOST}" ]]; then
  check_name "${CM_EXTERNAL_ACCESS_HOST}" "CM external access host"
  check_tcp "${CM_EXTERNAL_ACCESS_HOST}" "${CM_HTTP_PORT}" "CM external HTTP access"
fi

echo
echo "[OK] Connectivity check complete"
