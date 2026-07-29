#!/usr/bin/env bash
set -euo pipefail
export JAVA_TOOL_OPTIONS='-Djava.security.egd=file:/dev/urandom'

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TLS_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/cloudera-autotls-ssh-setup.XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

cat > "${TEST_ROOT}/hosts.csv" <<'CSV'
host_id,common_name,dns_sans,ip_sans
remote01.example.test,remote01.example.test,remote01.example.test,10.30.0.10
remote02.example.test,remote02.example.test,remote02.example.test,10.30.0.11
CSV

cat > "${TEST_ROOT}/fake-ssh-keygen" <<'EOF_KEYGEN'
#!/usr/bin/env bash
set -euo pipefail
output=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "${output}" ]]
mkdir -p "$(dirname "${output}")"
printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'TEST' '-----END OPENSSH PRIVATE KEY-----' > "${output}"
printf '%s\n' 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCTest cloudera-autotls' > "${output}.pub"
EOF_KEYGEN
chmod +x "${TEST_ROOT}/fake-ssh-keygen"

cat > "${TEST_ROOT}/fake-ssh" <<'EOF_SSH'
#!/usr/bin/env bash
set -euo pipefail
command_string="${!#}"
bash -c "${command_string}"
EOF_SSH
chmod +x "${TEST_ROOT}/fake-ssh"

cat > "${TEST_ROOT}/EXPORTS" <<EOF_EXPORTS
export AUTO_TLS_CERT_MODE='customer'
export AUTO_TLS_PREREQ_MODE='offline'
export AUTO_TLS_DRY_RUN='true'
export AUTO_TLS_HOSTS_CSV='${TEST_ROOT}/hosts.csv'
export AUTO_TLS_CM_HOST='remote01.example.test'
export AUTO_TLS_LOCATION='${TEST_ROOT}/AutoTLS'
export AUTO_TLS_KEYSTORE_PASSWORD='KeyStorePassword12345'
export AUTO_TLS_TRUSTSTORE_PASSWORD='TrustStorePassword12345'
export AUTO_TLS_ENCRYPT_HOST_KEYS='false'
export AUTO_TLS_HOST_KEY_PASSWORD=''
export AUTO_TLS_SSH_AUTO_SETUP='true'
export AUTO_TLS_SSH_USER='autotls'
export AUTO_TLS_SSH_HOME='/home/autotls'
export AUTO_TLS_SSH_KEY_FILE='/home/autotls/.ssh/id_rsa'
export AUTO_TLS_SSH_PUBLIC_KEY_FILE='/home/autotls/.ssh/id_rsa.pub'
export AUTO_TLS_SSH_SUDOERS_FILE='/etc/sudoers.d/autotls'
export AUTO_TLS_SSH_SETUP_SANDBOX_ROOT='${TEST_ROOT}/sandbox'
export AUTO_TLS_SSH_BIN='${TEST_ROOT}/fake-ssh'
export AUTO_TLS_SSH_KEYGEN_BIN='${TEST_ROOT}/fake-ssh-keygen'
export AUTO_TLS_BOOTSTRAP_USER='root'
export AUTO_TLS_BOOTSTRAP_USE_DEFAULT_IDENTITIES='true'
export AUTO_TLS_BOOTSTRAP_PASSWORD=''
export AUTO_TLS_OWNER='root:root'
export CLOUDERA_SERVICE_USER='nonexistent-test-user'
export SYSTEM_PYTHON_BIN='$(command -v python3)'
EOF_EXPORTS

export AUTO_TLS_EXPORTS_FILE="${TEST_ROOT}/EXPORTS"
cd "${TLS_DIR}"
bash 00_setup_autotls_ssh.sh > "${TEST_ROOT}/first.log" 2>&1
bash 00_setup_autotls_ssh.sh > "${TEST_ROOT}/second.log" 2>&1

HOME_DIR="${TEST_ROOT}/sandbox/home/autotls"
SUDOERS="${TEST_ROOT}/sandbox/etc/sudoers.d/autotls"
[[ -f "${HOME_DIR}/.ssh/id_rsa" ]]
[[ -f "${HOME_DIR}/.ssh/id_rsa.pub" ]]
[[ -f "${HOME_DIR}/.ssh/authorized_keys" ]]
[[ -f "${SUDOERS}" ]]
grep -q '^autotls ALL=(ALL) NOPASSWD:ALL$' "${SUDOERS}"
grep -q '^ssh-rsa ' "${HOME_DIR}/.ssh/authorized_keys"
[[ "$(grep -c '^ssh-rsa ' "${HOME_DIR}/.ssh/authorized_keys")" -eq 1 ]]
grep -q 'Installed Auto-TLS SSH identity on remote01.example.test' "${TEST_ROOT}/first.log"
grep -q 'Installed Auto-TLS SSH identity on remote02.example.test' "${TEST_ROOT}/first.log"
grep -q 'Auto-TLS SSH setup completed for 2 host(s)' "${TEST_ROOT}/second.log"

echo '[OK] Automatic SSH user/key distribution sandbox test passed.'
