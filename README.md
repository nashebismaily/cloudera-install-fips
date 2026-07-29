# CFM FIPS Install Kit

This repository prepares and installs a Cloudera Manager, CDP Runtime, and Cloudera Flow Management environment on FIPS-enabled RHEL 8.10.

The current default tested profile is defined in `EXPORTS`:

- RHEL 8.10
- Operating-system FIPS enabled before any Cloudera installation
- Cloudera Manager 7.13.1.0
- CDP Runtime 7.3.1
- CFM 2.1.7.3000 build 45
- NiFi and NiFi Registry 1.28.1
- PostgreSQL 14
- Java 11
- SafeLogic CCJ 3.0.2.1 and BCTLS modules from the approved CDP 7.1.9 SafeLogic bundle

For this tested environment, CDP Runtime 7.3.1 uses the same approved SafeLogic/FIPS jars as CDP 7.1.9. The SafeLogic source directory remains independently configurable through `FIPS_JAR_SOURCE_DIR` in `EXPORTS`.

## Configuration rule

`EXPORTS` is the single source of configuration for executable code.

The scripts do not contain fixed product versions, repository URLs, operating-system repository names, package lists, service names, service ports, Java paths, PostgreSQL paths, Cloudera paths, CSD names, or parcel names. Change those values in `EXPORTS`, not in the scripts.

The working password defaults are intentionally retained in `EXPORTS`, including the Cloudera Manager, Reports Manager, NiFi Registry, Hue, Hive, Ranger, NiFi sensitive-properties, and Auto-TLS defaults.

Run the repository audit after every code or configuration change:

```bash
bash tools/run_static_validation.sh
```

## Live-install issues addressed

The current code incorporates the lessons learned during the live FIPS installation:

1. The PGDG signing key is imported before the PostgreSQL repository RPM is installed.
2. Java alternatives is set to the full versioned Java 11 binary registered by RHEL.
3. `JAVA_HOME` remains the stable unversioned path required by Cloudera Manager.
4. Old versioned `JAVA_HOME` entries are normalized in managed Java and CM files.
5. The custom PostgreSQL data-directory parent is created with traversable permissions.
6. PostgreSQL ownership, permissions, and SELinux labels are applied to the custom data directory.
7. Managed SCRAM rules are inserted before conflicting existing PostgreSQL host rules.
8. SELinux mode changes are applied to the current boot and written persistently to the configured SELinux file.
9. `fapolicyd` defaults to stopped, disabled, and masked because it blocked Java from reading the SafeLogic jars during the live install.
10. SafeLogic directories and jars receive explicit ownership and permissions.
11. SafeLogic modules are tested as the `cloudera-scm` service user after that account exists.
12. Python 3.8 and the CM agent Python wrapper are installed and validated.
13. The manager host starts the local CM agent and supervisord so it appears as a managed host.
14. FIPS-compatible `psycopg2` is built from source for Hue/PostgreSQL readiness.
15. Local CM health is distinguished from external browser connectivity.
16. A missing CFM toolkit directory is treated as an expected warning until the CFM parcel is activated.

---

## 1. Host layout

The default workflow assumes at least two hosts:

| Role | Description |
|---|---|
| Manager | Runs Cloudera Manager Server, local PostgreSQL, the local Cloudera Manager Agent, and `cloudera-scm-supervisord` |
| Agent | Runs the Cloudera Manager Agent and `cloudera-scm-supervisord`, managed by the Manager |

Example values:

```bash
export MANAGER_HOST='cm01.example.com'
export AGENT_HOST='nifi01.example.com'
export ALLOWED_CIDR='10.0.0.0/20'
```

Use lowercase FQDNs or private DNS names that:

- resolve from every cluster host;
- resolve to the correct private IP address;
- are reachable inside the VPC or private network;
- match the hostnames Cloudera Manager will use;
- can be included in future TLS certificate SANs.

Validate on each host:

```bash
hostname
hostname -f
hostname -I
getent hosts "$(hostname -f)"
```

Validate cross-host resolution:

```bash
getent hosts cm01.example.com
getent hosts nifi01.example.com
```

---

## 2. Enable FIPS before running any Cloudera scripts

Run this on every Manager and agent host before installing Cloudera software.

```bash
sudo -i

cat /etc/redhat-release
uname -r

dnf install -y crypto-policies-scripts dracut-fips
fips-mode-setup --enable
sync
reboot
```

The SSH session will disconnect during the reboot.

After reconnecting, verify:

```bash
sudo -i

cat /etc/redhat-release
fips-mode-setup --check
cat /proc/sys/crypto/fips_enabled
update-crypto-policies --show
cat /proc/cmdline
```

Expected results include:

```text
Red Hat Enterprise Linux release 8.10
FIPS mode is enabled.
1
FIPS
```

The kernel command line should contain:

```text
fips=1
```

Combined validation:

```bash
set -e

fips-mode-setup --check
test "$(cat /proc/sys/crypto/fips_enabled)" = '1'
test "$(update-crypto-policies --show)" = 'FIPS'
grep -qw 'fips=1' /proc/cmdline

echo '[OK] RHEL operating-system FIPS mode is enabled.'
```

Do not install Cloudera Manager, CDP Runtime, CFM, PostgreSQL, or generate production certificates before FIPS is enabled.

---

## 3. Stage the install kit

### Clone the repository

On the Manager host:

```bash
sudo -i

dnf install -y git unzip
cd /root

git clone \
  https://github.com/nashebismaily/cloudera-install-fips.git \
  /root/cloudera-install-fips

cd /root/cloudera-install-fips
```

Confirm the branch and commit:

```bash
git branch --show-current
git log -1 --oneline
git status
```

The GitHub repository must contain the updated live-install fixes. A Git clone only retrieves changes that have already been committed and pushed.

Verify the updated files exist:

```bash
test -f EXPORTS
test -f RUN_MANAGER
test -f RUN_AGENT
test -f tools/audit_configurability.sh
test -f tools/run_static_validation.sh
```

Verify key live-install controls are present:

```bash
grep -n '^export PGDG_GPG_KEY_URL=' EXPORTS
grep -n "^export FAPOLICYD_MODE='disable'" EXPORTS
grep -n '^export JAVA_HOME_TARGET=' EXPORTS
grep -n '^export FIPS_JAR_SOURCE_DIR=' EXPORTS
```

### ZIP alternative

If using a ZIP instead of Git:

```bash
sudo -i
cd /root

unzip cloudera-install-fips-main-live-install-updated.zip
mv cloudera-install-fips-main cloudera-install-fips
cd /root/cloudera-install-fips
```

Set executable permissions:

```bash
chmod 700 RUN_MANAGER RUN_AGENT
chmod 700 ./*.sh
chmod 700 tools/*.sh
find utilities -type f -name '*.sh' -exec chmod 700 {} \;
```

The same repository and `EXPORTS` layout must be available on each agent host before running `RUN_AGENT`.

---

## 4. Stage the SafeLogic/FIPS jars on every applicable host

The Manager and every agent host must have local access to the approved CCJ and BCTLS source jars before `RUN_MANAGER` or `RUN_AGENT` runs.

The current tested defaults are:

```bash
export FIPS_JAR_SOURCE_DIR='/opt/cloudera/fips-jars/cdp-7.1.9'
export FIPS_CCJ_JAR='ccj-3.0.2.1.jar'
export FIPS_BCTLS_JAR='bctls.jar'
```

### Current ZIP bundle layout

A currently used bundle extracts as:

```text
/tmp/Safelogic/bctls.jar
/tmp/Safelogic/bctls.jar.sha256
/tmp/Safelogic/CCJ 3.0.2.1/ccj-3.0.2.1.jar
/tmp/Safelogic/CCJ 3.0.2.1/ccj-3.0.2.1.jar.sha256
```

If the bundle has not been extracted:

```bash
sudo -i
cd /tmp
unzip safelogic.zip
find /tmp/Safelogic -maxdepth 3 -type f -print
```

Remove macOS metadata if present:

```bash
rm -f /tmp/Safelogic/.DS_Store
```

### Verify the approved checksums

Use the `.sha256` files supplied with the approved package as the authority:

```bash
cd /tmp/Safelogic

BCTLS_EXPECTED="$(grep -Eio '[0-9a-f]{64}' bctls.jar.sha256 | head -1)"
BCTLS_ACTUAL="$(sha256sum bctls.jar | awk '{print $1}')"

CCJ_EXPECTED="$(grep -Eio '[0-9a-f]{64}' \
  'CCJ 3.0.2.1/ccj-3.0.2.1.jar.sha256' | head -1)"
CCJ_ACTUAL="$(sha256sum \
  'CCJ 3.0.2.1/ccj-3.0.2.1.jar' | awk '{print $1}')"

printf 'BCTLS expected: %s\n' "$BCTLS_EXPECTED"
printf 'BCTLS actual:   %s\n' "$BCTLS_ACTUAL"
printf 'CCJ expected:   %s\n' "$CCJ_EXPECTED"
printf 'CCJ actual:     %s\n' "$CCJ_ACTUAL"

[[ -n "$BCTLS_EXPECTED" && "${BCTLS_ACTUAL,,}" == "${BCTLS_EXPECTED,,}" ]] || {
  echo '[ERROR] BCTLS checksum failed'
  exit 1
}

[[ -n "$CCJ_EXPECTED" && "${CCJ_ACTUAL,,}" == "${CCJ_EXPECTED,,}" ]] || {
  echo '[ERROR] CCJ checksum failed'
  exit 1
}

echo '[OK] Both SafeLogic checksums passed.'
```

Validate that both jars are readable archives:

```bash
unzip -t /tmp/Safelogic/bctls.jar
unzip -t '/tmp/Safelogic/CCJ 3.0.2.1/ccj-3.0.2.1.jar'
```

Both should finish with `No errors detected`.

Previous validated reference values for this bundle were:

```text
5a73ed8d9029bdb5edfea0c90ef47fad09aaeed5baba3186fa9e87de518d44c8  bctls.jar
920358d92e36884908a23aa211cbdb7d877ed2703683e39470cd721a1033cf25  ccj-3.0.2.1.jar
```

Treat those as comparison values only. The checksums delivered with the approved SafeLogic package are authoritative.

### Stage using the configured destination

```bash
cd /root/cloudera-install-fips
source ./EXPORTS

install -d \
  -o root \
  -g root \
  -m 0755 \
  "$FIPS_JAR_SOURCE_DIR"

install \
  -o root \
  -g root \
  -m 0644 \
  /tmp/Safelogic/bctls.jar \
  "${FIPS_JAR_SOURCE_DIR}/${FIPS_BCTLS_JAR}"

install \
  -o root \
  -g root \
  -m 0644 \
  '/tmp/Safelogic/CCJ 3.0.2.1/ccj-3.0.2.1.jar' \
  "${FIPS_JAR_SOURCE_DIR}/${FIPS_CCJ_JAR}"

restorecon -RFv "$FIPS_JAR_SOURCE_DIR" 2>/dev/null || true
```

Validate:

```bash
find "$FIPS_JAR_SOURCE_DIR" \
  -maxdepth 1 \
  -type f \
  -printf '%M %u:%g %p\n'

sha256sum \
  "${FIPS_JAR_SOURCE_DIR}/${FIPS_BCTLS_JAR}" \
  "${FIPS_JAR_SOURCE_DIR}/${FIPS_CCJ_JAR}"
```

Expected ownership and permissions:

```text
-rw-r--r-- root:root .../bctls.jar
-rw-r--r-- root:root .../ccj-3.0.2.1.jar
```

### Tarball alternative

An older approved bundle may be supplied as:

```text
/tmp/Cloudera-CDP-PVC-Base-7.1.9-Safelogic-FIPS-Modules-20230815.tar.gz
```

Extract and locate the jars:

```bash
mkdir -p /root/safelogic

tar -xzvf \
  /tmp/Cloudera-CDP-PVC-Base-7.1.9-Safelogic-FIPS-Modules-20230815.tar.gz \
  -C /root/safelogic

find /root/safelogic -maxdepth 5 -type f -name '*.jar' -print
```

Copy the approved jars into the configured destination. For the original tarball layout, the exact source paths are:

```bash
cd /root/cloudera-install-fips
source ./EXPORTS

install -d -o root -g root -m 0755 "$FIPS_JAR_SOURCE_DIR"

install -o root -g root -m 0644 \
  "/root/safelogic/CCJ 3.0.2.1/ccj-3.0.2.1.jar" \
  "${FIPS_JAR_SOURCE_DIR}/${FIPS_CCJ_JAR}"

install -o root -g root -m 0644 \
  "/root/safelogic/BCTLS-CCJ 3.0.2.1/bctls.jar" \
  "${FIPS_JAR_SOURCE_DIR}/${FIPS_BCTLS_JAR}"
```

If the extracted tarball uses a different internal directory layout, use the `find` output to locate the two approved jars, then copy them into `FIPS_JAR_SOURCE_DIR` with root ownership and mode `0644`.

---

## 5. Configure `EXPORTS`

Back up and edit the file:

```bash
cd /root/cloudera-install-fips
cp -p EXPORTS "EXPORTS.original.$(date +%Y%m%d-%H%M%S)"
vi EXPORTS
```

At minimum, set the Cloudera archive credentials and host values:

```bash
export CLOUDERA_REPO_USER='your_cloudera_archive_username'
export CLOUDERA_REPO_PASS='your_cloudera_archive_password'

export MANAGER_HOST='cm01.example.com'
export AGENT_HOST='nifi01.example.com'
export ALLOWED_CIDR='10.0.0.0/20'
```

For the default profile, retain:

```bash
export EXPECTED_RHEL_MAJOR='8'
export EXPECTED_RHEL_MINOR='10'
export REQUIRE_FIPS='true'

export CM_VERSION='7.13.1.0'
export CDP_RUNTIME_VERSION='7.3.1'

export JAVA_MAJOR='11'
export JAVA_INSTALL_MODE='system'
export CUSTOM_JAVA_HOME=''
export JAVA_HOME_TARGET="/usr/lib/jvm/java-${JAVA_MAJOR}-openjdk"

export PG_MAJOR='14'
export PGDATA_DIR="/data/postgres${PG_MAJOR}"

export CFM_STREAM='cfm2'
export CFM_VERSION='2.1.7.3000'
export CFM_BUILD='45'
export NIFI_VERSION='1.28.1'
```

Derived values in the current default profile resolve to:

```text
NIFI-1.28.1.2.1.7.3000-45.jar
NIFIREGISTRY-1.28.1.2.1.7.3000-45.jar
CFM-2.1.7.3000-45
https://archive.cloudera.com/p/cfm2/2.1.7.3000/redhat8/yum/tars/parcel/
```

Do not mix CSDs and parcels from different CFM builds, such as CFM 2.1.7.3000 CSDs with CFM 2.1.7.1001 parcel artifacts.

Keep the SafeLogic source values aligned with the staged files:

```bash
export FIPS_JAR_SOURCE_DIR='/opt/cloudera/fips-jars/cdp-7.1.9'
export FIPS_BCTLS_JAR='bctls.jar'
export FIPS_CCJ_JAR='ccj-3.0.2.1.jar'
export FIPS_EXTRA_JARS=''
```

Although `CDP_RUNTIME_VERSION` is `7.3.1`, the source directory intentionally remains `cdp-7.1.9` because the tested CDP 7.3.1 environment uses that approved SafeLogic bundle.

### Password defaults

The working defaults remain in `EXPORTS` as requested:

| Purpose | Variable | Default |
|---|---|---|
| Cloudera Manager database | `CM_DB_PASS` | `ClouderaCM_2026` |
| Reports Manager database | `RM_DB_PASS` | `Rman_DB_2026` |
| NiFi Registry database | `REG_DB_PASS` | `Registry_DB_2026` |
| Hue database | `HUE_DB_PASS` | `Hue_DB_2026` |
| Hive Metastore database | `HIVE_DB_PASS` | `Hive_DB_2026` |
| Ranger database | `RANGER_DB_PASS` | `Ranger_DB_2026` |
| NiFi sensitive-properties key | `NIFI_SENSITIVE_PROPS_KEY` | `ChangeMeToAtLeast12Chars` |
| CM admin username | `CM_ADMIN_USER` | `admin` |
| CM admin password | `CM_ADMIN_PASSWORD` | `admin` |
| Auto-TLS host-key password | `AUTO_TLS_HOST_KEY_PASSWORD` | `ChangeMe12345` |
| Auto-TLS keystore password | `AUTO_TLS_KEYSTORE_PASSWORD` | `ChangeMe12345` |
| Auto-TLS truststore password | `AUTO_TLS_TRUSTSTORE_PASSWORD` | `ChangeMe12345` |
| Auto-TLS CA-key password | `AUTO_TLS_CA_KEY_PASSWORD` | `ChangeMe12345` |

These are working lab defaults. Change them for customer, shared, or production environments while keeping all values in `EXPORTS`.

### Important configuration groups

Review every section in `EXPORTS`, especially:

- Password defaults and Cloudera archive credentials
- Manager, agent, database, and external-access hosts
- Ports and connectivity timeouts
- RHEL and FIPS guardrails
- Red Hat, PGDG, EPEL, and Cloudera repository URLs
- SELinux, firewalld, and `fapolicyd` behavior
- THP, sysctl, and process limits
- Java version, packages, alternatives, stable `JAVA_HOME`, and Java security paths
- CM agent Python 3.8 packages and wrapper validation
- PostgreSQL packages, service, PGDATA, authentication, and JDBC driver
- Database names, users, and passwords
- Cloudera Manager versions, repository, packages, service names, and paths
- CDP Runtime version and parcel repository
- CFM version, build, CSD names, parcel name, and toolkit path
- SafeLogic source and active Java jar names, providers, module names, and permissions
- NiFi sensitive-properties algorithm and key
- Auto-TLS certificate, key, API, SSH, path, password, algorithm, and file-mode settings

### Load and inspect the configuration

```bash
cd /root/cloudera-install-fips
set -a
source ./EXPORTS
set +a
```

Display important non-secret values:

```bash
printf '%-32s %s\n' \
  MANAGER_HOST "$MANAGER_HOST" \
  AGENT_HOST "$AGENT_HOST" \
  ALLOWED_CIDR "$ALLOWED_CIDR" \
  CM_VERSION "$CM_VERSION" \
  CDP_RUNTIME_VERSION "$CDP_RUNTIME_VERSION" \
  CFM_VERSION "$CFM_VERSION" \
  CFM_BUILD "$CFM_BUILD" \
  CFM_PARCEL_REPO_URL "$CFM_PARCEL_REPO_URL" \
  CFM_PARCEL_DIR_NAME "$CFM_PARCEL_DIR_NAME" \
  JAVA_HOME_TARGET "$JAVA_HOME_TARGET" \
  PGDATA_DIR "$PGDATA_DIR" \
  FIPS_JAR_SOURCE_DIR "$FIPS_JAR_SOURCE_DIR"
```

Confirm archive credentials are populated without printing them:

```bash
[[ -n "$CLOUDERA_REPO_USER" ]] \
  && echo '[OK] Cloudera repository username configured' \
  || echo '[ERROR] Cloudera repository username is empty'

[[ -n "$CLOUDERA_REPO_PASS" ]] \
  && echo '[OK] Cloudera repository password configured' \
  || echo '[ERROR] Cloudera repository password is empty'
```

### Changing product versions

The version and URL derivations are visible and editable in `EXPORTS`:

```bash
export CLOUDERA_ARCHIVE_BASE_URL='https://archive.cloudera.com/p'
export CFM_STREAM='cfm2'
export CFM_VERSION='2.1.7.3000'
export CFM_BUILD='45'
export CFM_OS_REPO="redhat${EXPECTED_RHEL_MAJOR}"
export NIFI_VERSION='1.28.1'

export CFM_PARCEL_REPO_URL="${CLOUDERA_ARCHIVE_BASE_URL}/${CFM_STREAM}/${CFM_VERSION}/${CFM_OS_REPO}/yum/tars/parcel/"
export CFM_NIFI_CSD_JAR="NIFI-${NIFI_VERSION}.${CFM_VERSION}-${CFM_BUILD}.jar"
export CFM_NIFIREGISTRY_CSD_JAR="NIFIREGISTRY-${NIFI_VERSION}.${CFM_VERSION}-${CFM_BUILD}.jar"
export CFM_PARCEL_DIR_NAME="CFM-${CFM_VERSION}-${CFM_BUILD}"
```

When changing versions, verify the Cloudera support matrix and ensure the repository, parcel, NiFi CSD, NiFi Registry CSD, Java, PostgreSQL, operating system, and SafeLogic bundle are mutually compatible.

---

## 6. Validate the manager before installing

On the Manager host:

```bash
cd /root/cloudera-install-fips
source ./EXPORTS
```

First run static validation:

```bash
bash tools/run_static_validation.sh
```

Expected final messages:

```text
[OK] Configurability audit passed.
[OK] Static validation passed.
```

Then run the live preflight:

```bash
sudo -E bash 00_check_connectivity.sh 2>&1 | \
  tee "/root/cfm-preflight-$(date +%Y%m%d-%H%M%S).log"

test "${PIPESTATUS[0]}" -eq 0
```

Warnings for packages that have not yet been installed can be normal during the initial preflight, including missing Java, Python, DNS tools, `nc`, or `jq`. Later scripts install the configured packages.

Hard blockers include:

- wrong RHEL major or minor version;
- kernel FIPS not enabled;
- wrong system architecture;
- missing SafeLogic source jars;
- invalid Cloudera archive credentials;
- inaccessible Red Hat, PGDG, or Cloudera repositories;
- missing or unresolvable Manager/agent host values;
- no route between the agent and Manager;
- invalid configuration values.

Review warnings and errors:

```bash
grep -E '\[WARN\]|\[ERROR\]' \
  /root/cfm-preflight-*.log | tail -100
```

---

## 7. Run the manager install

On the Manager:

```bash
sudo -i
cd /root/cloudera-install-fips
source ./EXPORTS

./RUN_MANAGER 2>&1 | \
  tee "/root/run-manager-$(date +%Y%m%d-%H%M%S).log"

RUN_STATUS="${PIPESTATUS[0]}"
echo "RUN_MANAGER exit status: ${RUN_STATUS}"
exit "$RUN_STATUS"
```

The basic command is:

```bash
cd /root/cloudera-install-fips
source ./EXPORTS
sudo -E ./RUN_MANAGER
```

`RUN_MANAGER` runs these steps in order and stops on the first failure:

1. Platform and connectivity preflight
2. OS repository bootstrap
3. Common package installation
4. SELinux, firewalld, `fapolicyd`, THP, sysctl, and limit configuration
5. Java installation, alternatives selection, and SafeLogic provider configuration
6. PostgreSQL installation and custom data-directory initialization
7. PostgreSQL networking and SCRAM configuration
8. Cloudera service database and role creation
9. Cloudera Manager repository configuration
10. Cloudera Manager server and agent package installation
11. Local Manager-host CM agent configuration
12. Cloudera Manager database preparation
13. Cloudera Manager Server, local agent, and supervisord startup
14. CFM NiFi and NiFi Registry CSD installation
15. Manager ready-state validation

The Manager host must also run:

```text
cloudera-scm-supervisord
cloudera-scm-agent
```

Otherwise the Manager host may not appear as a managed host in Cloudera Manager.

After `RUN_MANAGER` completes, check:

```bash
source ./EXPORTS

systemctl status "$CM_SERVER_SERVICE" -l --no-pager
systemctl status "$CM_SUPERVISORD_SERVICE" -l --no-pager
systemctl status "$CM_AGENT_SERVICE" -l --no-pager
systemctl status "$PG_SERVICE_NAME" -l --no-pager

"$CM_AGENT_PYTHON_WRAPPER" --version

curl -I "${CM_HTTP_SCHEME}://${LOCALHOST_NAME}:${CM_HTTP_PORT}"

tail -n "$CM_SERVER_JOURNAL_LINES" "$CM_SERVER_LOG_FILE"
tail -n "$CM_AGENT_JOURNAL_LINES" /var/log/cloudera-scm-agent/cloudera-scm-agent.log
```

Open Cloudera Manager using the browser-reachable Manager address:

```text
http://<manager-host>:7180
```

The default configured login is:

```text
admin / admin
```

Use `CM_ADMIN_USER` and `CM_ADMIN_PASSWORD` from `EXPORTS` if changed.

If local `curl` succeeds but the browser cannot connect, do not reinstall CM. Check routing, security groups, network ACLs, VPN or bastion access, DNS, and the host firewall.

---

## 8. Run the agent install

The remote agent host needs:

- RHEL FIPS already enabled;
- the same current repository code;
- a locally edited `EXPORTS`;
- the approved SafeLogic source jars staged locally;
- network access to the Manager host.

### Clone on the agent

```bash
sudo -i

dnf install -y git unzip
cd /root

git clone \
  https://github.com/nashebismaily/cloudera-install-fips.git \
  /root/cloudera-install-fips

cd /root/cloudera-install-fips
chmod 700 RUN_AGENT RUN_MANAGER ./*.sh tools/*.sh
```

Alternatively, copy the exact validated repository from the Manager:

```bash
scp -r /root/cloudera-install-fips \
  root@nifi01.example.com:/root/
```

On the agent, confirm:

```bash
cd /root/cloudera-install-fips
vi EXPORTS
```

Set:

```bash
export MANAGER_HOST='cm01.example.com'
export AGENT_HOST='nifi01.example.com'
export ALLOWED_CIDR='10.0.0.0/20'
```

For additional agents, leave shared values unchanged and change only `AGENT_HOST` to the current agent’s FQDN or private DNS name.

The most important agent setting is:

```bash
export MANAGER_HOST='cm01.example.com'
```

Stage the SafeLogic jars as described in Section 4, then validate Manager reachability:

```bash
source ./EXPORTS

getent hosts "$MANAGER_HOST"
ping -c 2 "$MANAGER_HOST" || true
nc -zv "$MANAGER_HOST" "$CM_AGENT_PORT"
nc -zv "$MANAGER_HOST" "$CM_HTTP_PORT"
```

Run the preflight:

```bash
sudo -E bash 00_check_connectivity.sh
```

Run the agent installer:

```bash
./RUN_AGENT 2>&1 | \
  tee "/root/run-agent-$(date +%Y%m%d-%H%M%S).log"

RUN_STATUS="${PIPESTATUS[0]}"
echo "RUN_AGENT exit status: ${RUN_STATUS}"
exit "$RUN_STATUS"
```

The basic command is:

```bash
cd /root/cloudera-install-fips
source ./EXPORTS
sudo -E ./RUN_AGENT
```

Check the agent:

```bash
source ./EXPORTS

systemctl status "$CM_SUPERVISORD_SERVICE" -l --no-pager
systemctl status "$CM_AGENT_SERVICE" -l --no-pager
"$CM_AGENT_PYTHON_WRAPPER" --version

grep '^server_host=' "$CM_AGENT_CONFIG_FILE"
tail -n "$CM_AGENT_JOURNAL_LINES" /var/log/cloudera-scm-agent/cloudera-scm-agent.log
```

Both agent services should be active, and `server_host` should point to the Manager.

---

## 9. What the wrappers do

`RUN_MANAGER` and `RUN_AGENT` are fail-fast wrappers that source `EXPORTS` and call the numbered scripts in the required order.

Both wrappers use:

```bash
set -euo pipefail
```

If a numbered script exits with a non-zero status, the wrapper stops instead of continuing blindly.

Review the exact current execution sequence:

```bash
cat RUN_MANAGER
cat RUN_AGENT
```

The wrappers print each step and the exact command before executing it.

`RUN_MANAGER` intentionally does not run `14_install_cfm_fips_jars.sh` because the CFM parcel directory does not exist until the parcel has been downloaded, distributed, and activated through Cloudera Manager.

---

## 10. PostgreSQL model

The current default installs local PostgreSQL on the Manager host:

```bash
export PG_MAJOR='14'
export PGDATA_DIR="/data/postgres${PG_MAJOR}"
export DB_HOST='localhost'
export DB_PORT='5432'
```

Before `RUN_MANAGER`, verify the target filesystem has adequate capacity:

```bash
df -h
lsblk -f
ls -ld /data 2>/dev/null || true
```

The installation script:

- imports the PGDG signing key before installing the PGDG repository RPM;
- installs the configured PostgreSQL packages;
- creates the PGDATA parent with mode `0755`;
- creates PGDATA with mode `0700` and `postgres:postgres` ownership;
- configures the PostgreSQL service to use the custom PGDATA;
- applies PostgreSQL SELinux file contexts when `semanage` is available;
- initializes the database if `PG_VERSION` is absent;
- inserts managed SCRAM rules before older rules in `pg_hba.conf`;
- listens on the configured addresses and permits the configured `ALLOWED_CIDR`.

For an external PostgreSQL deployment, the code and `EXPORTS` would need an explicit external-database profile. Local PostgreSQL is the current tested default.

### Default database names, users, and passwords

The Manager workflow creates the following PostgreSQL databases by default:

| Purpose | Database | Username | Password | Notes |
|---|---|---|---|---|
| Cloudera Manager Server | `scm` | `scm` | `ClouderaCM_2026` | Used by `scm_prepare_database.sh` |
| Reports Manager | `rman` | `rman` | `Rman_DB_2026` | Enter in the CM Management Service Reports Manager configuration |
| NiFi Registry | `nifireg` | `nifireg` | `Registry_DB_2026` | Enter in the NiFi Registry database configuration |
| Hue, optional | `hue` | `hue` | `Hue_DB_2026` | Created only when `CREATE_EXTRA_DBS=true` |
| Hive Metastore, optional | `metastore` | `hive` | `Hive_DB_2026` | Created only when `CREATE_EXTRA_DBS=true` |
| Ranger, optional | `ranger` | `rangeradmin` | `Ranger_DB_2026` | Created only when `CREATE_EXTRA_DBS=true` |

The actual values come from these `EXPORTS` variables:

```bash
CM_DB_NAME CM_DB_USER CM_DB_PASS
RM_DB_NAME RM_DB_USER RM_DB_PASS
REG_DB_NAME REG_DB_USER REG_DB_PASS
HUE_DB_NAME HUE_DB_USER HUE_DB_PASS
HIVE_DB_NAME HIVE_DB_USER HIVE_DB_PASS
RANGER_DB_NAME RANGER_DB_USER RANGER_DB_PASS
```

The database host used by remote services is normally the Manager private DNS name rather than `localhost`.

### PostgreSQL JDBC driver

`11_prepare_cm_database.sh` ensures the configured JDBC package is installed and that a PostgreSQL JDBC jar exists under:

```bash
export POSTGRES_JDBC_PACKAGE='postgresql-jdbc'
export POSTGRES_JDBC_DIR='/usr/share/java'
export POSTGRES_JDBC_GLOB='postgresql*.jar'
```

Validate:

```bash
source ./EXPORTS

ls -lh "$POSTGRES_JDBC_DIR" | grep -i postgres
find "$POSTGRES_JDBC_DIR" -iname '*postgres*.jar' -print
```

### FIPS-safe Hue `psycopg2`

When enabled, the scripts build `psycopg2` from source instead of using `psycopg2-binary`:

```bash
export INSTALL_HUE_FIPS_PSYCOPG2='true'
export HUE_PSYCOPG2_VERSION='2.9.9'
```

This is executed during common/CM package preparation and validated with the configured Python runtime.

---

## 11. Cloudera Manager deployment sequence

After `RUN_MANAGER` and `RUN_AGENT` complete:

1. Log into Cloudera Manager.
2. Confirm the Manager/server host appears as a managed host.
3. Confirm each remote agent appears as a managed host.
4. Select the already managed hosts instead of reinstalling the agents over SSH.
5. Configure the CDP Runtime parcel repository if required.
6. Download, distribute, and activate CDP Runtime 7.3.1.
7. Deploy the required base services, including ZooKeeper.
8. Add the CFM parcel repository from `EXPORTS`.
9. Download, distribute, and activate the configured CFM parcel.
10. Run `14_install_cfm_fips_jars.sh` on every host that receives the CFM parcel and will run CFM roles.
11. Enable approved TLS or the optional Auto-TLS workflow.
12. Add NiFi and optionally NiFi Registry.
13. Apply the FIPS-specific NiFi and NiFi Registry settings.
14. Start and validate the services.

### Open Cloudera Manager

Default URL before Auto-TLS:

```text
http://<manager-host>:7180
```

Use the values from `EXPORTS`:

```bash
source ./EXPORTS
printf '%s://%s:%s\n' "$CM_HTTP_SCHEME" "$MANAGER_HOST" "$CM_HTTP_PORT"
```

### Use already managed hosts

Because `RUN_MANAGER` and `RUN_AGENT` install and start the agents, the hosts should appear under currently managed hosts. Do not run another uncontrolled agent installation over SSH unless the hosts fail to register.

If an agent does not appear:

```bash
source ./EXPORTS

systemctl restart "$CM_AGENT_SERVICE"
sleep "$SERVICE_SETTLE_SECONDS"
tail -n "$CM_AGENT_JOURNAL_LINES" /var/log/cloudera-scm-agent/cloudera-scm-agent.log
```

### CDP Runtime parcel

The scripts do not deploy CDP Runtime services. Set or confirm:

```bash
source ./EXPORTS
echo "$CDP_PARCEL_REPO_URL"
```

`CDP_PARCEL_REPO_URL` is intentionally empty in the default `EXPORTS` until the correct entitled CDP Runtime 7.3.1 parcel URL is selected for the environment.

Download, distribute, and activate CDP Runtime before CFM. ZooKeeper comes from CDP Runtime and should be deployed through Cloudera Manager rather than installed manually.

### CFM parcel repository

Display the exact configured URL:

```bash
source ./EXPORTS
echo "$CFM_PARCEL_REPO_URL"
echo "$CFM_PARCEL_DIR_NAME"
```

The default resolves to:

```text
https://archive.cloudera.com/p/cfm2/2.1.7.3000/redhat8/yum/tars/parcel/
CFM-2.1.7.3000-45
```

In Cloudera Manager:

```text
Hosts -> Parcels -> Configuration
```

Add the CFM repository URL, save, return to `Hosts -> Parcels`, check for new parcels, then download, distribute, and activate the configured CFM parcel.

The CFM CSDs installed by the scripts must match the parcel build:

```text
NIFI-1.28.1.2.1.7.3000-45.jar
NIFIREGISTRY-1.28.1.2.1.7.3000-45.jar
```

### Install the SafeLogic jars into the CFM parcel

After CFM activation, run on each host that will run NiFi or NiFi Registry:

```bash
cd /root/cloudera-install-fips
source ./EXPORTS

sudo -E bash 14_install_cfm_fips_jars.sh
sudo -E bash 15_validate_ready_state.sh
```

Validate:

```bash
ls -lh \
  "${CFM_TOOLKIT_LIB_DIR}/${FIPS_BCTLS_JAR}" \
  "${CFM_TOOLKIT_LIB_DIR}/${FIPS_CCJ_JAR}"
```

For the default parcel, the files are:

```text
/opt/cloudera/parcels/CFM-2.1.7.3000-45/TOOLKIT/lib/bctls.jar
/opt/cloudera/parcels/CFM-2.1.7.3000-45/TOOLKIT/lib/ccj-3.0.2.1.jar
```

If NiFi and NiFi Registry run only on an agent, script 14 is required on that agent. It is not required on the Manager unless the Manager will host a CFM role or also has the parcel and you want every parcel host prepared.

### NiFi Registry PostgreSQL configuration

When adding NiFi Registry, replace the embedded H2 defaults with PostgreSQL values derived from `EXPORTS`.

Display the values:

```bash
source /root/cloudera-install-fips/EXPORTS

REGISTRY_DB_HOST="${MANAGER_HOST}"
REGISTRY_JDBC_URL="jdbc:postgresql://${REGISTRY_DB_HOST}:${DB_PORT}/${REG_DB_NAME}"

printf 'JDBC URL:      %s\n' "$REGISTRY_JDBC_URL"
printf 'Driver:        %s\n' 'org.postgresql.Driver'
printf 'Driver dir:    %s\n' "$POSTGRES_JDBC_DIR"
printf 'Database user: %s\n' "$REG_DB_USER"
```

Use these fields in Cloudera Manager:

| CM field | Value |
|---|---|
| NiFi Registry JDBC URL | `jdbc:postgresql://<manager-host>:5432/nifireg` |
| NiFi Registry JDBC Driver | `org.postgresql.Driver` |
| NiFi Registry Database Driver Directory | `/usr/share/java` |
| NiFi Registry Database Username | `nifireg` |
| NiFi Registry Database Password | `Registry_DB_2026` |
| Maximum connections in DB pool | `5` |
| Enable database SQL debugging | `false` |

Use the actual values from `MANAGER_HOST`, `DB_PORT`, `REG_DB_NAME`, `REG_DB_USER`, `REG_DB_PASS`, and `POSTGRES_JDBC_DIR` if they differ.

Test from the NiFi Registry host:

```bash
source /root/cloudera-install-fips/EXPORTS

PGPASSWORD="$REG_DB_PASS" "${PG_BIN_DIR}/psql" \
  -h "$MANAGER_HOST" \
  -p "$DB_PORT" \
  -U "$REG_DB_USER" \
  -d "$REG_DB_NAME" \
  -c 'select current_database(), current_user;'
```

Expected values are the configured Registry database and user.

### NiFi post-install FIPS configuration

Some FIPS fields may not appear during the initial Add Service wizard. Add the NiFi service, then configure these settings before treating the service as complete.

#### Sensitive properties

In:

```text
NiFi -> Configuration
```

Search for `sensitive` and set:

```properties
nifi.sensitive.props.algorithm=NIFI_PBKDF2_AES_GCM_256
nifi.sensitive.props.key=<value from NIFI_SENSITIVE_PROPS_KEY>
```

The current lab default key is retained in `EXPORTS`, but replace it with a real environment-specific key for customer or production environments.

#### NiFi bootstrap Java module arguments

Display the current parcel paths:

```bash
source /root/cloudera-install-fips/EXPORTS

printf 'CCJ:   %s/%s\n' "$CFM_TOOLKIT_LIB_DIR" "$FIPS_CCJ_JAR"
printf 'BCTLS: %s/%s\n' "$CFM_TOOLKIT_LIB_DIR" "$FIPS_BCTLS_JAR"
```

In Cloudera Manager, search for `bootstrap` and use:

```text
NiFi Node Advanced Configuration Snippet (Safety Valve) for staging/bootstrap.conf.xml
```

For the current default profile, add:

```xml
<property>
  <name>java.arg.200</name>
  <value>--module-path=/opt/cloudera/parcels/CFM-2.1.7.3000-45/TOOLKIT/lib/ccj-3.0.2.1.jar:/opt/cloudera/parcels/CFM-2.1.7.3000-45/TOOLKIT/lib/bctls.jar</value>
</property>
<property>
  <name>java.arg.201</name>
  <value>--add-exports=java.base/sun.security.provider=com.safelogic.cryptocomply.fips.core</value>
</property>
<property>
  <name>java.arg.202</name>
  <value>--add-modules=com.safelogic.cryptocomply.fips.core,bctls</value>
</property>
<property>
  <name>java.arg.203</name>
  <value>-Dcom.safelogic.cryptocomply.fips.approved_only=true</value>
</property>
<property>
  <name>java.arg.204</name>
  <value>-Djdk.tls.trustNameService=true</value>
</property>
<property>
  <name>java.arg.205</name>
  <value>-Djdk.tls.ephemeralDHKeySize=2048</value>
</property>
<property>
  <name>java.arg.206</name>
  <value>-Dorg.bouncycastle.jsse.client.assumeOriginalHostName=true</value>
</property>
```

If `java.arg.200` through `java.arg.206` are already used, choose unused argument numbers while keeping the values unchanged.

If the CFM version, build, parcel root, or jar names change, replace the paths with the resolved `EXPORTS` values. Do not copy the default path blindly into a different release.

Confirm module names on the NiFi host:

```bash
source /root/cloudera-install-fips/EXPORTS

"$JAVA_HOME_TARGET/bin/jar" \
  --file="${CFM_TOOLKIT_LIB_DIR}/${FIPS_CCJ_JAR}" \
  --describe-module | head -5

"$JAVA_HOME_TARGET/bin/jar" \
  --file="${CFM_TOOLKIT_LIB_DIR}/${FIPS_BCTLS_JAR}" \
  --describe-module | head -5
```

For the default CFM parcel, the expected module names are:

```text
ccj-3.0.2.1.jar -> com.safelogic.cryptocomply.fips.core
bctls.jar       -> bctls
```

After saving the NiFi configuration, start or restart NiFi and validate the generated process directory:

```bash
sudo -i

NIFI_PROC_DIR="$(ls -td \
  /var/run/cloudera-scm-agent/process/*NIFI* \
  /var/run/cloudera-scm-agent/process/*nifi* \
  2>/dev/null | head -1)"

echo "$NIFI_PROC_DIR"

grep -n \
  'java.arg.20\|module-path\|add-modules\|safelogic\|bctls' \
  "$NIFI_PROC_DIR/bootstrap.conf"
```

If NiFi fails with:

```text
java.security.NoSuchAlgorithmException: X.509 KeyManagerFactory not available
```

confirm the bootstrap module arguments are present in the generated `bootstrap.conf` and that both CFM toolkit jars exist and are readable.

### NiFi Registry FIPS/TLS settings

After Auto-TLS, if NiFi Registry fails with an X.509 KeyManagerFactory error, set:

```properties
nifi.registry.security.keymanager.algorithm=PKIX
nifi.registry.security.trustmanager.algorithm=PKIX
```

Use direct fields if exposed in Cloudera Manager. Otherwise use the NiFi Registry advanced configuration snippet for `nifi-registry.properties`.

Ensure the keystore and truststore types match the stores assigned by Cloudera Manager:

```properties
nifi.registry.security.keystoreType=JKS
nifi.registry.security.truststoreType=JKS
```

or:

```properties
nifi.registry.security.keystoreType=PKCS12
nifi.registry.security.truststoreType=PKCS12
```

Confirm the effective Registry configuration:

```bash
grep -i \
  'keymanager\|trustmanager\|keystoreType\|truststoreType' \
  /var/run/cloudera-scm-agent/process/*-NIFI_REGISTRY-*/nifi-registry.properties \
  2>/dev/null
```

---

## 12. Do not run the SafeLogic parcel-copy script too early

Do not run this immediately after `RUN_MANAGER`:

```bash
sudo -E bash 14_install_cfm_fips_jars.sh
```

The script copies the staged source jars into:

```bash
$CFM_TOOLKIT_LIB_DIR
```

The default path resolves to:

```text
/opt/cloudera/parcels/CFM-2.1.7.3000-45/TOOLKIT/lib
```

That directory does not exist until the CFM parcel has been downloaded, distributed, and activated.

The correct order is:

```text
Run RUN_MANAGER
Run RUN_AGENT on every agent
Log into Cloudera Manager
Select the already managed hosts
Download/distribute/activate CDP Runtime
Deploy ZooKeeper and required base services
Add the CFM parcel repository
Download/distribute/activate the CFM parcel
Run 14_install_cfm_fips_jars.sh on each applicable CFM host
Run 15_validate_ready_state.sh
Enable TLS
Create/configure NiFi and NiFi Registry
```

Before parcel activation, this warning is expected:

```text
[WARN] CFM toolkit lib dir not found yet. This is expected before the CFM parcel is activated.
```

After activation:

```bash
cd /root/cloudera-install-fips
source ./EXPORTS

sudo -E bash 14_install_cfm_fips_jars.sh
sudo -E bash 15_validate_ready_state.sh
```

---

## 13. Auto-TLS approach

The optional Auto-TLS workflow is under:

```text
utilities/tls
```

The top-level `EXPORTS` is the primary configuration source. `utilities/tls/tls.env` is optional and should contain only local overrides.

Use this top-level README for the full platform installation and `utilities/tls/README.md` for utility-specific Auto-TLS details.

For production or customer environments, use certificates and a CA approved by the organization. The included demo CA scripts are intended for lab validation unless the customer explicitly approves that approach.

### When to run Auto-TLS

Run Auto-TLS only after:

1. `RUN_MANAGER` completed successfully.
2. `RUN_AGENT` completed successfully on every agent.
3. All hosts appear in Cloudera Manager.
4. Cloudera Manager responds on the configured HTTP port.
5. CM API credentials work.
6. Forward DNS resolution works for every hostname in `hosts.csv`.
7. Passwordless SSH works from the Manager to every host using the configured Auto-TLS user and key.
8. That SSH user has passwordless sudo on every host.
9. The `host_id` values in `hosts.csv` exactly match the hostnames known by Cloudera Manager.

Do not run Auto-TLS before the agents are installed and communicating with CM.

### Auto-TLS utility files

| File | Purpose |
|---|---|
| `README.md` | Utility-specific instructions |
| `tls.env.example` | Optional local override template |
| `hosts.csv.example` | Host inventory template |
| `00_prepare_dirs.sh` | Creates configured artifact directories |
| `01_generate_keys_csrs.sh` | Generates encrypted or unencrypted host keys and CSRs |
| `02_create_demo_ca.sh` | Creates the configured local demo CA |
| `03_sign_csrs_with_demo_ca.sh` | Signs host CSRs |
| `04_build_pkcs12_stores.sh` | Builds configured PKCS12 stores |
| `05_validate_autotls_prereqs.sh` | Validates CM API, DNS, SSH, paths, credentials, and required artifacts |
| `06_validate_artifacts.sh` | Validates keys, certificates, SANs, chains, and stores |
| `07_enable_autotls.sh` | Builds the `generateCmca` payload and calls the CM API |

Do not commit customer-specific `tls.env`, `hosts.csv`, private keys, passwords, or generated artifacts.

### Example `hosts.csv`

```csv
host_id,ip_sans,dns_sans
cm01.example.com,10.0.11.4,cm01.example.com
nifi01.example.com,10.0.12.5,nifi01.example.com
```

The `host_id` must match the hostname Cloudera Manager knows for that host.

### Configure Auto-TLS in `EXPORTS`

Common values include:

```bash
export AUTO_TLS_CM_HOST="${MANAGER_HOST}"
export AUTO_TLS_HOSTS_CSV='/root/cloudera-install-fips/utilities/tls/hosts.csv'
export AUTO_TLS_SSH_USER='autotls'
export AUTO_TLS_SSH_PORT='22'
export AUTO_TLS_SSH_KEY_FILE='/home/autotls/.ssh/id_rsa'
export AUTO_TLS_ENCRYPT_HOST_KEYS='true'
```

Create the inventory:

```bash
cd /root/cloudera-install-fips/utilities/tls
cp hosts.csv.example hosts.csv
vi hosts.csv
```

Optional local overrides:

```bash
cp tls.env.example tls.env
vi tls.env
```

The Auto-TLS passwords are retained in top-level `EXPORTS`. The validation requires applicable passwords to be alphanumeric and longer than 12 characters.

### Configure the Auto-TLS SSH user

Create or confirm the configured SSH user and passwordless sudo on every host. Example sudoers entry:

```text
autotls ALL=(ALL) NOPASSWD:ALL
```

From the Manager, test:

```bash
ssh -i /home/autotls/.ssh/id_rsa \
  autotls@cm01.example.com 'hostname -f && sudo true'

ssh -i /home/autotls/.ssh/id_rsa \
  autotls@nifi01.example.com 'hostname -f && sudo true'
```

### Encrypted and unencrypted host key modes

For customer or live environments, use encrypted host keys:

```bash
export AUTO_TLS_ENCRYPT_HOST_KEYS='true'
export AUTO_TLS_HOST_KEY_PASSWORD='ChangeMe12345'
```

In encrypted mode, `07_enable_autotls.sh` creates the per-host password file required by Cert Manager:

```text
/opt/cloudera/AutoTLS/hosts-key-store/<hostname>/cm-auto-host_key.pw
```

For temporary lab testing only:

```bash
export AUTO_TLS_ENCRYPT_HOST_KEYS='false'
```

In unencrypted mode, the scripts remove stale per-host password files before calling Auto-TLS.

### Auto-TLS execution sequence

On the Manager:

```bash
sudo -i
cd /root/cloudera-install-fips
source ./EXPORTS
cd utilities/tls
```

For a deliberate clean lab rebuild only, remove old generated Auto-TLS artifacts before regenerating them. Do not run this against artifacts that must be preserved:

```bash
rm -rf "$AUTO_TLS_WORKDIR"
rm -rf "$AUTO_TLS_HOSTS_KEY_STORE_DIR"
```

Then run:

```bash
sudo -E bash 00_prepare_dirs.sh
sudo -E bash 01_generate_keys_csrs.sh
sudo -E bash 02_create_demo_ca.sh
sudo -E bash 03_sign_csrs_with_demo_ca.sh
sudo -E bash 04_build_pkcs12_stores.sh
sudo -E bash 05_validate_autotls_prereqs.sh
sudo -E bash 06_validate_artifacts.sh
sudo -E bash 07_enable_autotls.sh
```

Do not run step 07 until steps 05 and 06 both pass.

### What `05_validate_autotls_prereqs.sh` checks

The prerequisite script validates:

- required local commands;
- required `EXPORTS` and optional override values;
- password format requirements;
- `hosts.csv` structure and host entries;
- forward DNS resolution through DNS or an approved `/etc/hosts` entry;
- CM API availability and credentials;
- passwordless SSH to every host;
- configured directory ownership and accessibility;
- required CA, host key, and certificate artifacts.

### What `07_enable_autotls.sh` does

The script submits its payload to the configured endpoint, which defaults to:

```text
http://<CM_HOST>:7180/api/<CM_API_VERSION>/cm/commands/generateCmca
```

The script:

- validates each host private key with the configured encrypted/unencrypted mode;
- creates per-host password files for encrypted host keys;
- removes stale password files in unencrypted mode;
- creates the configured keystore and truststore password files;
- builds a JSON payload containing the Auto-TLS location, CA certificate, CM host certificate/key, every host certificate/key, and password-file paths;
- embeds the configured SSH user and private-key access method;
- sends `configureAllServices=true` when `AUTO_TLS_CONFIGURE_ALL_SERVICES='true'` in `EXPORTS`;
- submits the payload to the configured `generateCmca` API endpoint;
- accepts the configured success HTTP status codes;
- prints the logs and HTTPS URL to use afterward.

If Cert Manager reports:

```text
No password file found for host ... cm-auto-host_key.pw
Assuming default in-cluster password
unable to load private key
bad decrypt
```

verify that the per-host password file exists and contains the exact password used to encrypt the host key.

### After `07_enable_autotls.sh` succeeds

Watch:

```bash
source /root/cloudera-install-fips/EXPORTS

tail -f "$CM_SERVER_LOG_FILE"
tail -f "$CM_CERTMANAGER_LOG_FILE"
```

Restart the configured CM services:

```bash
systemctl restart "$CM_SERVER_SERVICE"
systemctl restart "$CM_AGENT_SERVICE"
```

Restart the agent on each remote host, for example:

```bash
ssh -i "$AUTO_TLS_SSH_KEY_FILE" \
  "${AUTO_TLS_SSH_USER}@nifi01.example.com" \
  "sudo systemctl restart ${CM_AGENT_SERVICE}"
```

Open the HTTPS UI:

```bash
printf '%s://%s:%s\n' \
  "$CM_HTTPS_SCHEME" \
  "$AUTO_TLS_CM_HOST" \
  "$CM_HTTPS_PORT"
```

The default HTTPS port is `7183`.

Finally, restart the Cloudera Management Service and cluster services from the Cloudera Manager UI as needed.

---

## 14. Version changes later

The install kit is designed to be version-configurable through `EXPORTS`.

To change Cloudera Manager, update the CM version and any release-specific repository attributes in `EXPORTS`:

```bash
export CM_VERSION='7.13.1.0'
export CM_MAJOR_REPO='cm7'
export CM_OS_REPO="redhat${EXPECTED_RHEL_MAJOR}"
```

To change CDP Runtime:

```bash
export CDP_RUNTIME_VERSION='7.3.1'
export CDP_PARCEL_REPO_URL='<approved entitled parcel URL>'
```

To change CFM/NiFi:

```bash
export CFM_STREAM='cfm2'
export CFM_VERSION='<new CFM version>'
export CFM_BUILD='<new build>'
export NIFI_VERSION='<matching NiFi version>'
```

Confirm that all derived CSD, parcel, and repository values resolve to the intended release:

```bash
source ./EXPORTS

printf '%s\n' \
  "$CFM_PARCEL_REPO_URL" \
  "$CFM_NIFI_CSD_JAR" \
  "$CFM_NIFIREGISTRY_CSD_JAR" \
  "$CFM_PARCEL_DIR_NAME" \
  "$CFM_TOOLKIT_LIB_DIR"
```

If SafeLogic jars change:

```bash
export FIPS_JAR_SOURCE_DIR='/opt/cloudera/fips-jars/<new-approved-bundle>'
export FIPS_BCTLS_JAR='<new-bctls-source-name>'
export FIPS_CCJ_JAR='<new-ccj-source-name>'
export FIPS_EXTRA_JARS=''
```

Also review the active Java FIPS names, provider classes, module names, Java security configuration, and NiFi bootstrap module names.

After any version change:

```bash
bash tools/run_static_validation.sh
```

Static validation confirms syntax, required configuration, derived artifact names, and the no-hardcoding audit. It does not replace a live support-matrix check or a full installation test.

---

## 15. Quick command summary

### Manager preparation and install

```bash
sudo -i
cd /root/cloudera-install-fips

source ./EXPORTS
bash tools/run_static_validation.sh
sudo -E bash 00_check_connectivity.sh
sudo -E ./RUN_MANAGER
```

### Agent preparation and install

```bash
sudo -i
cd /root/cloudera-install-fips

source ./EXPORTS
bash tools/run_static_validation.sh
sudo -E bash 00_check_connectivity.sh
sudo -E ./RUN_AGENT
```

### After CFM parcel activation

Run on every applicable CFM role host:

```bash
sudo -i
cd /root/cloudera-install-fips

source ./EXPORTS
sudo -E bash 14_install_cfm_fips_jars.sh
sudo -E bash 15_validate_ready_state.sh
```

### Show the configured CFM parcel URL

```bash
cd /root/cloudera-install-fips
source ./EXPORTS
echo "$CFM_PARCEL_REPO_URL"
```

### Validate final host state

```bash
cd /root/cloudera-install-fips
source ./EXPORTS
sudo -E bash 15_validate_ready_state.sh
```

---

## Update: CM Agent Python 3.8 is required on RHEL 8

During testing, the CM agent failed with an exit status similar to:

```text
ExecStart=/opt/cloudera/cm-agent/bin/cm agent (code=exited, status=126)
```

In the original failure, the wrapper also produced errors such as:

```text
/usr/local/bin/: Is a directory
exec: /usr/local/bin/: cannot execute: Is a directory
```

The CM agent wrapper expects the configured Python 3.8 runtime:

```bash
export CM_AGENT_PYTHON_MAJOR='3.8'
export CM_AGENT_PYTHON_MODULE='python38'
export CM_AGENT_PYTHON_BIN='/usr/bin/python3.8'
export CM_AGENT_PYTHON_WRAPPER='/opt/cloudera/cm-agent/bin/python'
export CM_AGENT_PYTHON_PACKAGES='python38 python38-devel python38-pip'
export CM_AGENT_PYTHON_STRICT_VERSION='true'
```

The scripts install and validate Python 3.8 on both Manager and agent hosts because the Manager also runs a local agent.

Expected validation:

```bash
source ./EXPORTS
"$CM_AGENT_PYTHON_WRAPPER" --version
```

Expected output:

```text
Python 3.8.x
```

If the agent exits with status `126`, check:

```bash
source ./EXPORTS

ls -l "$CM_AGENT_PYTHON_WRAPPER"
"$CM_AGENT_PYTHON_WRAPPER" --version
ls -l "$CM_AGENT_PYTHON_BIN"
systemctl status "$CM_AGENT_SERVICE" -l --no-pager
journalctl -u "$CM_AGENT_SERVICE" -n "$CM_AGENT_JOURNAL_LINES" --no-pager
```

---

## Update: Java SafeLogic FIPS setup is required before CM startup

During live testing, CM Server failed with:

```text
java.security.KeyManagementException: FIPS mode: only SunJSSE TrustManagers may be used
```

The fix is not to disable operating-system FIPS. The SafeLogic providers must be staged and configured for Java before CM Server starts.

The scripts now do this automatically through `04_install_java11_fips_runtime.sh`, `10_configure_cm_agent.sh`, and `12_start_cm_services.sh`.

### Java alternatives versus `JAVA_HOME`

The code deliberately uses two different paths:

- `alternatives --set java` receives the full versioned Java binary registered by RHEL.
- Cloudera Manager receives the stable `JAVA_HOME`, normally `/usr/lib/jvm/java-11-openjdk`.

This prevents Java 8 from remaining active while avoiding the versioned `JAVA_HOME` that Cloudera Manager rejected during the live install.

Validate:

```bash
source ./EXPORTS

java -version
readlink -f "$(command -v java)"
echo "$JAVA_HOME_TARGET"
grep -n 'JAVA_HOME' \
  "$JAVA_PROFILE_FILE" \
  "$JAVA_DEFAULT_FILE" \
  "$CM_SERVER_DEFAULTS_FILE" \
  2>/dev/null
```

### Three SafeLogic locations

There are three separate locations:

```text
/opt/cloudera/fips-jars/cdp-7.1.9
```

Versioned source staging directory. This contains the original approved `bctls.jar` and `ccj-3.0.2.1.jar`.

```text
/opt/cloudera/fips
```

Active Java/CM FIPS provider directory. The scripts copy and rename the jars here as:

```text
ccj-3.0.2.1.jar
bctls-safelogic.jar
```

```text
/opt/cloudera/parcels/CFM-*/TOOLKIT/lib
```

CFM/NiFi FIPS directory. This does not exist until the CFM parcel is activated. Script 14 copies the original parcel-compatible names here:

```text
ccj-3.0.2.1.jar
bctls.jar
```

### Active Java FIPS work performed by the scripts

The current implementation:

1. Creates the configured active Java FIPS directory with mode `0755`.
2. Copies the CCJ jar unchanged.
3. Copies source `bctls.jar` as `bctls-safelogic.jar` for the active Java module path.
4. Sets root ownership and mode `0644` on both jars.
5. Runs `restorecon` when available.
6. Writes the configured `JDK_JAVA_OPTIONS` profile.
7. Backs up and patches Java `java.policy` and `java.security`.
8. Loads and validates providers `CCJ` and `BCJSSE`.
9. Tests both modules as the `cloudera-scm` account after that account exists.
10. Writes the CM Server FIPS properties to the configured CM defaults file.

Validate the active modules:

```bash
source ./EXPORTS
source "$JAVA_FIPS_PROFILE_FILE"

java --module-path="${JAVA_FIPS_DIR}/${JAVA_FIPS_CCJ_JAR}:${JAVA_FIPS_DIR}/${JAVA_FIPS_BCTLS_JAR}" \
  --list-modules | egrep 'safelogic|bctls|cryptocomply'
```

Validate specifically as the service account:

```bash
source ./EXPORTS

sudo -u "$CLOUDERA_SERVICE_USER" \
  env -u JDK_JAVA_OPTIONS \
  "$JAVA_HOME_TARGET/bin/java" \
  --module-path="${JAVA_FIPS_DIR}/${JAVA_FIPS_CCJ_JAR}:${JAVA_FIPS_DIR}/${JAVA_FIPS_BCTLS_JAR}" \
  --list-modules | egrep 'safelogic|bctls|cryptocomply'
```

Expected modules include:

```text
bctls.safelogic
com.safelogic.cryptocomply.fips.core
```

Provider validation should include:

```text
Provider: CCJ
Provider: BCJSSE
```

To enumerate the active Java security providers manually:

```bash
cat > /root/ListSecurityProviders.java <<'JAVACODE'
import java.security.Provider;
import java.security.Security;

public class ListSecurityProviders {
  public static void main(String[] args) {
    for (Provider provider : Security.getProviders()) {
      System.out.println("Provider: " + provider.getName());
      System.out.println("Info: " + provider.getInfo());
    }
  }
}
JAVACODE

source ./EXPORTS
source "$JAVA_FIPS_PROFILE_FILE"
java /root/ListSecurityProviders.java | \
  egrep 'Provider:|CCJ|BCJSSE|Bouncy|CryptoComply'
```

Expected output includes `Provider: CCJ` and `Provider: BCJSSE`.

---

## Update: `fapolicyd` blocked the SafeLogic jars

The decisive live-install blocker was `fapolicyd`, not ordinary Unix permissions and not SELinux alone.

The failure appeared as Java being unable to read a jar even though permissions looked correct:

```text
Operation not permitted
```

The default configuration is therefore:

```bash
export FAPOLICYD_MODE='disable'
```

`03_configure_os.sh` stops, disables, and masks the configured service.

Validate:

```bash
source ./EXPORTS

systemctl is-active "$FAPOLICYD_SERVICE" || true
systemctl is-enabled "$FAPOLICYD_SERVICE" || true
systemctl status "$FAPOLICYD_SERVICE" -l --no-pager || true
```

For this tested profile, the service should not be active. If organizational policy requires `fapolicyd`, a tested allow-list policy for the SafeLogic jars and Java process is required before changing `FAPOLICYD_MODE` from `disable`.

---

## Update: SELinux behavior is persistent and configurable

The current defaults are:

```bash
export SELINUX_MODE='disabled'
export SELINUX_CONFIG_FILE='/etc/selinux/config'
```

Supported modes are:

```text
unchanged
permissive
disabled
```

For `permissive` or `disabled`, the script calls `setenforce 0` for the current boot and updates the configured SELinux file so the change survives reboot.

Validate:

```bash
source ./EXPORTS

getenforce
grep '^SELINUX=' "$SELINUX_CONFIG_FILE"
```

SELinux was not the final root cause of the SafeLogic jar failure, but persistent configuration prevents the running mode and boot-time mode from silently diverging during this tested installation flow.

---

## Update: PGDG key import and PostgreSQL PGDATA permissions

The live PostgreSQL repository failure was:

```text
Public key for pgdg-redhat-repo-latest.noarch.rpm is not installed
Error: GPG check FAILED
```

`01_bootstrap_repos.sh` now imports:

```bash
$PGDG_GPG_KEY_URL
```

before installing:

```bash
$PGDG_REPO_RPM_URL
```

The PostgreSQL installer also creates the PGDATA parent and data directory using configurable modes:

```bash
export PGDATA_PARENT_MODE='0755'
export PGDATA_DIR_MODE='0700'
export PGDATA_OWNER='postgres:postgres'
```

Validate after installation:

```bash
source ./EXPORTS

ls -ld "$(dirname "$PGDATA_DIR")" "$PGDATA_DIR"
stat -c '%A %U:%G %n' "$(dirname "$PGDATA_DIR")" "$PGDATA_DIR"
systemctl status "$PG_SERVICE_NAME" -l --no-pager
```

---

## Update: Manager host also runs agent and supervisord

The Cloudera Manager server host must also be a managed host. The Manager therefore runs:

```text
cloudera-scm-server
cloudera-scm-supervisord
cloudera-scm-agent
```

`10_configure_cm_agent.sh` and `12_start_cm_services.sh` enable, restart, and validate the local agent and supervisord.

Quick validation:

```bash
source ./EXPORTS

systemctl status "$CM_SERVER_SERVICE" -l --no-pager
systemctl status "$CM_SUPERVISORD_SERVICE" -l --no-pager
systemctl status "$CM_AGENT_SERVICE" -l --no-pager
"$CM_AGENT_PYTHON_WRAPPER" --version
```

---

## Update: Local CM health versus browser/network access

During the live install, CM listened successfully on its configured ports and local `curl` returned HTTP 200, but the browser could not reach the host.

That indicates an external access-path problem rather than a failed CM installation.

Validate locally on the Manager:

```bash
source ./EXPORTS

ss -plnt | grep ":${CM_HTTP_PORT}"
curl -I "${CM_HTTP_SCHEME}://${LOCALHOST_NAME}:${CM_HTTP_PORT}"
```

If those pass, check:

- the browser’s route to the private host;
- EC2 or cloud security groups;
- network ACLs;
- subnet and route-table configuration;
- VPN or bastion access;
- host firewall rules;
- DNS resolution;
- the value of `CM_EXTERNAL_ACCESS_HOST`.

The scripts can validate local health and configured TCP endpoints, but they cannot automatically repair cloud routing or security-group policy.

---

## Repository verification

Run before every live test and after every script edit:

```bash
cd /root/cloudera-install-fips
bash tools/run_static_validation.sh
```

The static validation performs:

- Bash syntax checks;
- required configuration checks;
- password/default presence checks;
- derived CFM artifact-name checks;
- the configurability/no-hardcoding audit.

Run only the hardcoding audit with:

```bash
bash tools/audit_configurability.sh
```

The audit fails when executable code contains embedded HTTP URLs, semantic release values, repository platform names, absolute operational paths, CFM/CSD artifact names, or standard service ports that should instead come from `EXPORTS`.

A passing static audit confirms repository structure and configurability. It does not replace a full live RHEL, systemd, PostgreSQL, SafeLogic, Cloudera Manager, CDP Runtime, CFM, NiFi, and Auto-TLS validation.
