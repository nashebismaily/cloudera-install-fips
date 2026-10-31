#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

ensure_hosts_csv
validate_bool AUTO_TLS_SSH_AUTO_SETUP
validate_bool AUTO_TLS_SSH_PASSWORDLESS_SUDO
validate_bool AUTO_TLS_BOOTSTRAP_USE_DEFAULT_IDENTITIES
validate_bool AUTO_TLS_BOOTSTRAP_REQUIRE_SUDO
validate_bool AUTO_TLS_SSH_SETUP_PLAN_ONLY

if [[ "${AUTO_TLS_SSH_AUTO_SETUP}" != "true" ]]; then
  echo "[INFO] Automatic Auto-TLS SSH setup is disabled."
  exit 0
fi

if [[ -z "${AUTO_TLS_SSH_SETUP_SANDBOX_ROOT}" && "${EUID}" -ne 0 ]]; then
  fail "Run this script as root on the Cloudera Manager server"
fi

require_cmd "${AUTO_TLS_SSH_KEYGEN_BIN}"
require_cmd "${AUTO_TLS_BASE64_BIN}"
require_cmd "${AUTO_TLS_SSH_BIN}"

path_with_root() {
  local path="$1"
  if [[ -n "${AUTO_TLS_SSH_SETUP_SANDBOX_ROOT}" ]]; then
    printf '%s%s' "${AUTO_TLS_SSH_SETUP_SANDBOX_ROOT}" "${path}"
  else
    printf '%s' "${path}"
  fi
}

LOCAL_SSH_HOME="$(path_with_root "${AUTO_TLS_SSH_HOME}")"
LOCAL_KEY_FILE="$(path_with_root "${AUTO_TLS_SSH_KEY_FILE}")"
LOCAL_PUBLIC_KEY_FILE="$(path_with_root "${AUTO_TLS_SSH_PUBLIC_KEY_FILE}")"
LOCAL_SUDOERS_FILE="$(path_with_root "${AUTO_TLS_SSH_SUDOERS_FILE}")"
LOCAL_AUTHORIZED_KEYS="${LOCAL_SSH_HOME}/.ssh/authorized_keys"

create_local_account_and_key() {
  if [[ "${AUTO_TLS_SSH_SETUP_PLAN_ONLY}" == "true" ]]; then
    echo "[PLAN] Create/reuse user ${AUTO_TLS_SSH_USER} with home ${AUTO_TLS_SSH_HOME}"
    echo "[PLAN] Create/reuse key ${AUTO_TLS_SSH_KEY_FILE}"
    echo "[PLAN] Install sudoers rule ${AUTO_TLS_SSH_SUDOERS_FILE}"
    return
  fi

  if [[ -z "${AUTO_TLS_SSH_SETUP_SANDBOX_ROOT}" ]]; then
    if ! id "${AUTO_TLS_SSH_USER}" >/dev/null 2>&1; then
      useradd --create-home --home-dir "${AUTO_TLS_SSH_HOME}" --shell /bin/bash "${AUTO_TLS_SSH_USER}"
      echo "[OK] Created local Auto-TLS user: ${AUTO_TLS_SSH_USER}"
    else
      echo "[PASS] Local Auto-TLS user already exists: ${AUTO_TLS_SSH_USER}"
    fi
  fi

  if [[ -z "${AUTO_TLS_SSH_SETUP_SANDBOX_ROOT}" ]]; then
    install -d -o "${AUTO_TLS_SSH_USER}" -g "${AUTO_TLS_SSH_USER}" -m 0700 "${LOCAL_SSH_HOME}/.ssh"
  else
    install -d -m 0700 "${LOCAL_SSH_HOME}/.ssh"
  fi

  if [[ ! -f "${LOCAL_KEY_FILE}" || ! -f "${LOCAL_PUBLIC_KEY_FILE}" ]]; then
    rm -f "${LOCAL_KEY_FILE}" "${LOCAL_PUBLIC_KEY_FILE}"
    if [[ -n "${AUTO_TLS_SSH_SETUP_SANDBOX_ROOT}" ]]; then
      "${AUTO_TLS_SSH_KEYGEN_BIN}" -q -m PEM -t "${AUTO_TLS_SSH_KEY_TYPE}" \
        -b "${AUTO_TLS_SSH_KEY_BITS}" -N '' -C "${AUTO_TLS_SSH_KEY_COMMENT}" \
        -f "${LOCAL_KEY_FILE}"
    else
      runuser -u "${AUTO_TLS_SSH_USER}" -- "${AUTO_TLS_SSH_KEYGEN_BIN}" \
        -q -m PEM -t "${AUTO_TLS_SSH_KEY_TYPE}" -b "${AUTO_TLS_SSH_KEY_BITS}" \
        -N '' -C "${AUTO_TLS_SSH_KEY_COMMENT}" -f "${AUTO_TLS_SSH_KEY_FILE}"
    fi
    echo "[OK] Generated dedicated Auto-TLS SSH keypair"
  else
    echo "[PASS] Dedicated Auto-TLS SSH keypair already exists"
  fi

  touch "${LOCAL_AUTHORIZED_KEYS}"
  grep -qxF "$(cat "${LOCAL_PUBLIC_KEY_FILE}")" "${LOCAL_AUTHORIZED_KEYS}" 2>/dev/null \
    || cat "${LOCAL_PUBLIC_KEY_FILE}" >> "${LOCAL_AUTHORIZED_KEYS}"
  chmod 0700 "${LOCAL_SSH_HOME}/.ssh"
  chmod 0600 "${LOCAL_KEY_FILE}" "${LOCAL_AUTHORIZED_KEYS}"
  chmod 0644 "${LOCAL_PUBLIC_KEY_FILE}"

  if [[ "${AUTO_TLS_SSH_PASSWORDLESS_SUDO}" == "true" ]]; then
    install -d -m 0750 "$(dirname "${LOCAL_SUDOERS_FILE}")"
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${AUTO_TLS_SSH_USER}" > "${LOCAL_SUDOERS_FILE}"
    chmod 0440 "${LOCAL_SUDOERS_FILE}"
    if [[ -z "${AUTO_TLS_SSH_SETUP_SANDBOX_ROOT}" ]] && command -v "${AUTO_TLS_VISUDO_BIN}" >/dev/null 2>&1; then
      "${AUTO_TLS_VISUDO_BIN}" -cf "${LOCAL_SUDOERS_FILE}" >/dev/null
    fi
  fi

  if [[ -z "${AUTO_TLS_SSH_SETUP_SANDBOX_ROOT}" ]]; then
    chown -R "${AUTO_TLS_SSH_USER}:${AUTO_TLS_SSH_USER}" "${AUTO_TLS_SSH_HOME}/.ssh"
  fi
}

remote_installer_script() {
  cat <<'REMOTE_EOF'
set -euo pipefail
user_name="$1"
user_home="$2"
sudoers_file="$3"
passwordless_sudo="$4"
public_key_b64="$5"
sandbox_root="$6"

rooted() {
  if [[ -n "${sandbox_root}" ]]; then
    printf '%s%s' "${sandbox_root}" "$1"
  else
    printf '%s' "$1"
  fi
}

target_home="$(rooted "${user_home}")"
target_sudoers="$(rooted "${sudoers_file}")"
ssh_dir="${target_home}/.ssh"
authorized_keys="${ssh_dir}/authorized_keys"

if [[ -z "${sandbox_root}" ]]; then
  if ! id "${user_name}" >/dev/null 2>&1; then
    useradd --create-home --home-dir "${user_home}" --shell /bin/bash "${user_name}"
  fi
fi

install -d -m 0700 "${ssh_dir}"
touch "${authorized_keys}"
public_key="$(printf '%s' "${public_key_b64}" | base64 -d)"
grep -qxF "${public_key}" "${authorized_keys}" 2>/dev/null || printf '%s\n' "${public_key}" >> "${authorized_keys}"
chmod 0600 "${authorized_keys}"

if [[ "${passwordless_sudo}" == "true" ]]; then
  install -d -m 0750 "$(dirname "${target_sudoers}")"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${user_name}" > "${target_sudoers}"
  chmod 0440 "${target_sudoers}"
  if [[ -z "${sandbox_root}" ]] && command -v visudo >/dev/null 2>&1; then
    visudo -cf "${target_sudoers}" >/dev/null
  fi
fi

if [[ -z "${sandbox_root}" ]]; then
  chown -R "${user_name}:${user_name}" "${user_home}/.ssh"
fi
REMOTE_EOF
}

build_bootstrap_ssh_args() {
  BOOTSTRAP_SSH_ARGS=(
    -p "${AUTO_TLS_BOOTSTRAP_PORT}"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o "ConnectTimeout=${AUTO_TLS_SSH_CONNECT_TIMEOUT_SECONDS}"
  )
  if [[ -n "${AUTO_TLS_BOOTSTRAP_KEY_FILE}" ]]; then
    require_file "${AUTO_TLS_BOOTSTRAP_KEY_FILE}"
    BOOTSTRAP_SSH_ARGS+=( -i "${AUTO_TLS_BOOTSTRAP_KEY_FILE}" -o IdentitiesOnly=yes -o BatchMode=yes )
  elif [[ "${AUTO_TLS_BOOTSTRAP_USE_DEFAULT_IDENTITIES}" == "true" && -z "${AUTO_TLS_BOOTSTRAP_PASSWORD}" ]]; then
    BOOTSTRAP_SSH_ARGS+=( -o BatchMode=yes )
  fi
}

run_bootstrap_ssh() {
  local host="$1" remote_command="$2" input_file="$3"
  build_bootstrap_ssh_args
  if [[ -n "${AUTO_TLS_BOOTSTRAP_PASSWORD}" ]]; then
    require_cmd sshpass
    SSHPASS="${AUTO_TLS_BOOTSTRAP_PASSWORD}" sshpass -e "${AUTO_TLS_SSH_BIN}" \
      "${BOOTSTRAP_SSH_ARGS[@]}" "${AUTO_TLS_BOOTSTRAP_USER}@${host}" \
      "${remote_command}" < "${input_file}"
  else
    "${AUTO_TLS_SSH_BIN}" "${BOOTSTRAP_SSH_ARGS[@]}" \
      "${AUTO_TLS_BOOTSTRAP_USER}@${host}" "${remote_command}" < "${input_file}"
  fi
}

install_remote_account_and_key() {
  local host="$1" pub_b64 remote_prefix remote_command tmp_script
  pub_b64="$("${AUTO_TLS_BASE64_BIN}" -w 0 "${LOCAL_PUBLIC_KEY_FILE}" 2>/dev/null || "${AUTO_TLS_BASE64_BIN}" "${LOCAL_PUBLIC_KEY_FILE}" | tr -d '\n')"

  if [[ "${AUTO_TLS_SSH_SETUP_PLAN_ONLY}" == "true" ]]; then
    echo "[PLAN] Bootstrap ${AUTO_TLS_BOOTSTRAP_USER}@${host}, create ${AUTO_TLS_SSH_USER}, install key and sudoers"
    return
  fi

  remote_prefix='bash -s --'
  if [[ "${AUTO_TLS_BOOTSTRAP_USER}" != "root" && "${AUTO_TLS_BOOTSTRAP_REQUIRE_SUDO}" == "true" ]]; then
    remote_prefix='sudo -n bash -s --'
  fi
  printf -v remote_command '%s %q %q %q %q %q %q' \
    "${remote_prefix}" "${AUTO_TLS_SSH_USER}" "${AUTO_TLS_SSH_HOME}" \
    "${AUTO_TLS_SSH_SUDOERS_FILE}" "${AUTO_TLS_SSH_PASSWORDLESS_SUDO}" \
    "${pub_b64}" "${AUTO_TLS_SSH_SETUP_SANDBOX_ROOT}"

  tmp_script="$(mktemp)"
  remote_installer_script > "${tmp_script}"
  if ! run_bootstrap_ssh "${host}" "${remote_command}" "${tmp_script}"; then
    rm -f "${tmp_script}"
    fail "Could not bootstrap Auto-TLS SSH on ${host}. Configure AUTO_TLS_BOOTSTRAP_USER and either AUTO_TLS_BOOTSTRAP_KEY_FILE, normal SSH agent/default identities, or AUTO_TLS_BOOTSTRAP_PASSWORD."
  fi
  rm -f "${tmp_script}"
  echo "[OK] Installed Auto-TLS SSH identity on ${host}"
}

validate_dedicated_ssh() {
  local host="$1"
  if [[ "${AUTO_TLS_SSH_SETUP_PLAN_ONLY}" == "true" ]]; then
    return
  fi
  local args=(
    -p "${AUTO_TLS_SSH_PORT}"
    -i "${LOCAL_KEY_FILE}"
    -o IdentitiesOnly=yes
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o "ConnectTimeout=${AUTO_TLS_SSH_CONNECT_TIMEOUT_SECONDS}"
  )
  local check='hostname -f'
  [[ "${AUTO_TLS_SSH_PASSWORDLESS_SUDO}" == "true" ]] && check+=' && sudo -n true'
  "${AUTO_TLS_SSH_BIN}" "${args[@]}" "${AUTO_TLS_SSH_USER}@${host}" "${check}" >/dev/null
  echo "[PASS] Dedicated Auto-TLS SSH works: ${AUTO_TLS_SSH_USER}@${host}"
}

create_local_account_and_key

mapfile -t HOSTS < <(read_host_ids)
for host in "${HOSTS[@]}"; do
  if is_local_host "${host}"; then
    if [[ "${AUTO_TLS_SSH_SETUP_PLAN_ONLY}" == "true" ]]; then
      echo "[PLAN] Authorize dedicated key on local manager host ${host}"
    else
      echo "[PASS] Local manager host prepared: ${host}"
    fi
  else
    install_remote_account_and_key "${host}"
  fi
done

if [[ "${AUTO_TLS_SSH_SETUP_PLAN_ONLY}" != "true" ]]; then
  # The real configured path is used by the Auto-TLS payload. In sandbox tests,
  # validation is performed by the test harness with a stub SSH command.
  if [[ -z "${AUTO_TLS_SSH_SETUP_SANDBOX_ROOT}" ]]; then
    for host in "${HOSTS[@]}"; do
      validate_dedicated_ssh "${host}"
    done
  fi
fi

echo "[OK] Auto-TLS SSH setup completed for ${#HOSTS[@]} host(s)"
