#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

need_root
log_init "00_check_connectivity"

validate_platform

install_preflight_diagnostic_tools() {
  local packages=()

  echo "==== Preflight diagnostic tools ===="

  # curl is required for HTTP/repository reachability checks.
  if ! command -v curl >/dev/null 2>&1; then
    packages+=("curl")
  fi

  # bind-utils provides host and nslookup.
  if ! command -v host >/dev/null 2>&1 || \
     ! command -v nslookup >/dev/null 2>&1; then
    packages+=("bind-utils")
  fi

  # nmap-ncat provides nc.
  if ! command -v nc >/dev/null 2>&1; then
    packages+=("nmap-ncat")
  fi

  # jq is useful for API/JSON validation later in the workflow.
  if ! command -v jq >/dev/null 2>&1; then
    packages+=("jq")
  fi

  if [[ ${#packages[@]} -eq 0 ]]; then
    echo "[OK] Preflight diagnostic tools already installed"
    echo
    return 0
  fi

  echo "[INFO] Installing missing preflight diagnostic packages:"
  printf '  - %s\n' "${packages[@]}"

  if dnf install -y "${packages[@]}"; then
    echo "[OK] Preflight diagnostic tools installed"
  else
    echo "[WARN] Could not install one or more preflight diagnostic packages."
    echo "[WARN] Connectivity validation will continue with available tools."
  fi

  echo
}

check_http() {
  local url="$1"
  local name="$2"

  if ! command -v curl >/dev/null 2>&1; then
    echo "[WARN] curl missing; skipping ${name} HTTP check"
    return 0
  fi

  if curl_head_public "${url}"; then
    echo "[OK] ${name} reachable: ${url}"
  else
    echo "[WARN] ${name} not reachable: ${url}"
  fi
}

check_tcp() {
  local host="$1"
  local port="$2"
  local name="$3"

  if command -v nc >/dev/null 2>&1; then
    if nc -zw"${TCP_CONNECT_TIMEOUT_SECONDS}" \
      "${host}" "${port}" >/dev/null 2>&1; then
      echo "[OK] ${name} reachable at ${host}:${port}"
    else
      echo "[WARN] ${name} not reachable at ${host}:${port}"
    fi
  else
    echo "[WARN] nc missing; skipping ${name} TCP check"
  fi
}

check_name() {
  local host="$1"
  local name="$2"

  if getent ahosts "${host}" >/dev/null 2>&1; then
    echo "[OK] ${name} resolves: ${host}"
    getent ahosts "${host}" | head -3 || true
  else
    echo "[WARN] ${name} does not resolve: ${host}"
  fi

  if [[ "${PREFLIGHT_PING_HOSTS}" == "true" ]] && \
     command -v ping >/dev/null 2>&1; then

    if ping -c 1 \
      -W "${TCP_CONNECT_TIMEOUT_SECONDS}" \
      "${host}" >/dev/null 2>&1; then
      echo "[OK] ${name} responds to ICMP: ${host}"
    else
      echo "[WARN] ${name} did not respond to ICMP; this may be blocked by policy."
    fi
  fi
}

check_basic_command() {
  local command_name="$1"

  #
  # Java and Python are intentionally NOT installed by preflight.
  #
  # Python is installed/configured during the common-package /
  # Cloudera Manager Agent preparation.
  #
  # Java is installed and FIPS-configured by
  # 04_install_java11_fips_runtime.sh.
  #
  case "${command_name}" in
    java|python3)
      if command -v "${command_name}" >/dev/null 2>&1; then
        echo "[OK] command present: ${command_name}"
      else
        echo "[INFO] command not installed yet: ${command_name} (installed later in workflow)"
      fi
      ;;
    *)
      warn_cmd "${command_name}"
      ;;
  esac
}

#
# Install only lightweight diagnostic utilities required by preflight.
# Do NOT install Java or Python here.
#
install_preflight_diagnostic_tools

echo "==== Basic commands ===="

read -r -a commands <<< "${PREFLIGHT_COMMANDS}"

for command_name in "${commands[@]}"; do
  check_basic_command "${command_name}"
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

systemctl is-active \
  "${FIREWALLD_SERVICE}" 2>/dev/null || true

systemctl is-enabled \
  "${FIREWALLD_SERVICE}" 2>/dev/null || true

systemctl is-active \
  "${FAPOLICYD_SERVICE}" 2>/dev/null || true

systemctl is-enabled \
  "${FAPOLICYD_SERVICE}" 2>/dev/null || true

timedatectl || true
chronyc tracking || true

echo
echo "==== DNF repos ===="

dnf repolist || true

echo
echo "==== Internet/repo reachability ===="

check_http \
  "${REDHAT_CDN_URL}" \
  "Red Hat CDN"

check_http \
  "${PGDG_CONNECTIVITY_URL}" \
  "PostgreSQL PGDG"

check_http \
  "${CLOUDERA_CONNECTIVITY_URL}" \
  "Cloudera archive"

if [[ "${ENABLE_EPEL}" == "true" ]]; then
  check_http \
    "${EPEL_CONNECTIVITY_URL}" \
    "EPEL"
fi

echo
echo "==== Cloudera protected repo checks ===="

if [[ -n "${CLOUDERA_REPO_USER}" && \
      -n "${CLOUDERA_REPO_PASS}" ]]; then

  echo "CM repo: ${CM_REPO_BASE_URL}"

  if curl_head_auth "${CM_REPO_BASE_URL}"; then
    echo "[OK] CM repo reachable with supplied credentials"
  else
    echo "[WARN] CM repo not reachable with supplied credentials"
  fi

  echo "CFM parcel repo: ${CFM_PARCEL_REPO_URL}"

  if curl_head_auth "${CFM_PARCEL_REPO_URL}"; then
    echo "[OK] CFM parcel repo reachable with supplied credentials"
  else
    echo "[WARN] CFM parcel repo not reachable with supplied credentials"
  fi

else
  echo "[INFO] CLOUDERA_REPO_USER/PASS not set; skipping protected repo auth checks"
fi

echo
echo "==== East/west checks ===="

if [[ -n "${MANAGER_HOST}" ]]; then

  check_name \
    "${MANAGER_HOST}" \
    "Manager host"

  check_tcp \
    "${MANAGER_HOST}" \
    "${CM_HTTP_PORT}" \
    "CM HTTP UI"

  check_tcp \
    "${MANAGER_HOST}" \
    "${CM_AGENT_PORT}" \
    "CM agent heartbeat listener"

  check_tcp \
    "${MANAGER_HOST}" \
    "${DB_PORT}" \
    "PostgreSQL"
fi

if [[ -n "${AGENT_HOST}" ]]; then

  check_name \
    "${AGENT_HOST}" \
    "Agent host"

  check_tcp \
    "${AGENT_HOST}" \
    "${AGENT_TCP_CHECK_PORT}" \
    "Agent host management/SSH port"

  if [[ "${CHECK_ZOOKEEPER_PORT}" == "true" ]]; then
    check_tcp \
      "${AGENT_HOST}" \
      "${ZOOKEEPER_CLIENT_PORT}" \
      "ZooKeeper client port"
  fi
fi

if [[ -n "${CM_EXTERNAL_ACCESS_HOST}" ]]; then

  check_name \
    "${CM_EXTERNAL_ACCESS_HOST}" \
    "CM external access host"

  check_tcp \
    "${CM_EXTERNAL_ACCESS_HOST}" \
    "${CM_HTTP_PORT}" \
    "CM external HTTP access"
fi

echo
echo "[OK] Connectivity check complete"
