# RHEL 9.8 installation — HTTP lab with OS and Java FIPS

The standard installation uses **no TLS on CM, agents, CDP services, NiFi, Registry or PostgreSQL**. It does not request certificates, private keys, CA files, certificate DNs or Auto-TLS passwords. The optional, independently configured tools are in the repository's separate **`TLS/`** folder. Nothing in this core installation sources or invokes them.

## 1. Target and required inputs

| Component | Selection |
|---|---|
| Operating system | RHEL **9.8 x86_64**, OS FIPS enabled first |
| Cloudera Manager | **7.13.2.10000** |
| CDP Runtime | **7.3.2.10000 / 7.3.2 SP1** |
| CFM | **4.12.0.10001**, NiFi / Registry **2.6.0** |
| Java | Supported upstream **JDK17** for CM/CDP; **JDK21** for NiFi/Registry |
| Python | **3.11**, alongside the OS interpreter; preserve the packaged CM agent wrapper |
| Database | PostgreSQL **16**, SCRAM-SHA-256, **SSL disabled** |
| Crypto | Supplied SP1 SafeLogic **CCJ4.0.0**, BCTLS2.0.17.1, BCUTIL2.0.1 and release-matched Cloudera SASL |

RHEL9.8 is the customer's internally confirmed target. Public Cloudera FIPS deployment documentation currently lists RHEL9.6. This is a **plaintext lab profile retaining OS/Java FIPS configuration**, not a claim of an encrypted or fully accepted production deployment. Sources are in [SOURCES.md](SOURCES.md).

Required inputs are entitled archive credentials, hostnames/network CIDR and the real approved SafeLogic JARs/sidecars. Both upstream JDKs are installed automatically by step04. **No TLS input is required.**

For a two-instance lab, use one manager and one agent. A single CM-managed ZooKeeper instance can run on the manager for this lab; NiFi/Registry can run on the agent. Production sizing/quorum planning is separate.

## 2. Prepare both hosts

Use **x86_64**, not an ARM/aarch64 instance. Confirm stable FQDNs, forward/reverse DNS, mounted storage and access to RHEL BaseOS/AppStream/CodeReady, PGDG and the pinned Cloudera archives.

```bash
hostname -f
uname -m
cat /etc/redhat-release
cat /proc/sys/crypto/fips_enabled
fips-mode-setup --check
update-crypto-policies --show
df -h
lsblk -f
```

Require RHEL9.8, x86_64, kernel FIPS flag1, a successful FIPS check and the approved FIPS crypto policy. If FIPS is already enabled, continue. Otherwise enable it using the approved Red Hat procedure on the clean host and reboot before continuing:

```bash
dnf install -y crypto-policies-scripts dracut-fips
fips-mode-setup --enable
reboot
```

The wrappers install the OS/build/runtime prerequisites and apply the deployment lessons: stop/disable/mask **firewalld and fapolicyd**, persist the configured SELinux mode, disable THP, tune swappiness/sysctls/limits, enable chrony/rngd, prepare Python3.11 and the native PostgreSQL adapter. Disabling fapolicyd precedes source builds/provider loading. RHEL9 entropy256 is normal; RHEL8 entropy thresholds/OpenSSL `.hmac` workarounds are not used.

Allow the relevant network/security-group paths:

| Traffic | Default TCP port |
|---|---|
| CM UI/API | **7180 HTTP** |
| Agents → CM heartbeat | **7182**, `use_tls=0` |
| NiFi UI/API | **8080 HTTP** |
| Registry UI/API | **18080 HTTP** |
| PostgreSQL clients → manager | **5432**, non-SSL SCRAM |
| SSH management | 22 |
| ZooKeeper client / quorum / election | 2181 / 2888 / 3888, as configured |
| NiFi cluster / load balancing | 9088 / 6342, as configured |

Add actual site-to-site and any other selected service ports. No 7183/8443/18443 listener or certificate provisioning is part of this profile. HTTP NiFi/Registry access is unauthenticated; there is no NiFi username, administrator DN or certificate login to configure.

## 3. Stage this revision and edit EXPORTS on each host

Use the rebuilt ZIP/patch or the repository revision containing this change. If the remote still contains the earlier build, apply/push the supplied update first. In a clean source checkout:

```bash
git clone https://github.com/nashebismaily/cloudera-install-fips.git /root/cloudera-install-fips
cd /root/cloudera-install-fips/RHEL9
vi EXPORTS
chmod 600 EXPORTS
```

Preserve existing deployment credentials before updating an edited `EXPORTS`; do not overwrite the only copy. Edit the existing assignments before their derived values:

```bash
export CLOUDERA_REPO_USER='your_archive_user'
export CLOUDERA_REPO_PASS='your_archive_password'
export MANAGER_HOST='manager-private-fqdn'
export AGENT_HOST='this-host-private-fqdn'
export ALLOWED_CIDR='10.0.0.0/20'
```

Use `MANAGER_HOST=hostname -f` on the manager and the worker's own FQDN for its `AGENT_HOST`. `DB_HOST` defaults to the manager. Replace lab database and NiFi sensitive-property passwords as appropriate; FIPS crypto/password fields retain the minimum14-character checks. CM initially uses its normal bootstrap account, commonly admin/admin; rotate that account in CM after first login.

Keep these standard-profile values:

```text
INSTALL_PROFILE=http-lab
CM_RUNTIME_PROTOCOL=http
CM_RUNTIME_PORT=7180
DB_SSLMODE=disable
NIFI_HTTP_PORT=8080
NIFI_REGISTRY_HTTP_PORT=18080
```

There are no core TLS passwords, certificate-source paths or CA-file assignments to fill in.

## 4. Stage SafeLogic on both hosts; Java is installed automatically

Place the real supplied archive at the configured `FIPS_BUNDLE_ARCHIVE`, default:

```text
/root/Cloudera-Base-on-premise-7.3.2-SP1-Safelogic-FIPS-Modules-07282026.tar.gz
```

Or place its seven JARs and original SHA256 sidecars directly in `FIPS_JAR_SOURCE_DIR`, default `/opt/cloudera/fips-jars/cdp-7.3.2.10000`. The screenshot identifies:

```text
ccj-4.0.0-fips.jar     bctls-2.0.17.1.jar     bcutil-2.0.1.jar
bcpkix-2.0.6.jar       bcmail-2.0.4.jar       bcpg-2.0.6.jar
bcpqc-8.5.jar
```

Every JAR must have its supplied `.sha256` sidecar. The preparer validates all seven, rejects unsafe/duplicate archive members and retains the original artifacts. Only the three core provider/support JARs and Cloudera SASL are placed on the shared module path `/opt/cloudera/fips`; extra bundle libraries are not indiscriminately added to every classpath.

SASL is not in the screenshot. The preparer resolves the matching `sasl-sha256aes-0.1.0.7.3.2.10000-<build>.jar` from the entitled Maven repository, validates the provider class and records its digest/provenance. If the listing is ambiguous, set the exact `FIPS_SASL_JAR` or stage the approved JAR and sidecar. It also resolves the pinned EL9 parcels and both matching CSDs and writes `artifacts.json`; internal build numbers are not guessed.

Do not stage Java for the standard connected installation. Preflight checks the host/network and required site inputs without requiring an existing JDK, JDK archive or Java checksum. Step04 resolves the upstream Eclipse Temurin Linux x64 JDK17/21 releases, obtains their vendor-published SHA256 values through verified HTTPS, downloads and verifies each archive, and installs complete homes at `/opt/java/jdk-17` and `/opt/java/jdk-21`. The selected release/download/checksum is recorded under `/var/cache/cloudera-bootstrap/jdks`. Complete existing upstream homes are reused on reruns.

Both JDKs then receive the CCJ/BCJSSE/SASL provider configuration and approved-only flags. CM/CDP stay on17; both CFM services explicitly use21. The Red Hat-modified JDK RPMs are not used for the SafeLogic runtime. Repository HTTPS downloads need access to `api.adoptium.net`, GitHub release downloads and their redirected artifact hosts, in addition to the existing package repositories. This does not enable service TLS.

Disconnected deployments may optionally supply `JAVA_ARCHIVE_FILE` / `JAVA_ARCHIVE_SHA256` and `CFM_JAVA_ARCHIVE_FILE` / `CFM_JAVA_ARCHIVE_SHA256`; step04 verifies these overrides. They are not required or checked by preflight.

The core automatically preserves the JDK's public CA roots in BCFKS for **outbound HTTPS archive downloads**. This needs no customer CA/certificate/key and enables no server TLS listener. Normal verified HTTPS repository downloads are independent of the lab services' HTTP/non-SSL configuration.

## 5. Run manager and agent installation

On the manager:

```bash
cd /root/cloudera-install-fips/RHEL9
source ./EXPORTS
sudo -E bash 00_check_connectivity.sh manager
sudo -E ./RUN_MANAGER
```

On the agent:

```bash
cd /root/cloudera-install-fips/RHEL9
source ./EXPORTS
sudo -E bash 00_check_connectivity.sh agent
sudo -E ./RUN_AGENT
```

`RUN_MANAGER` verifies inputs/entitled artifacts → repositories → OS controls → packages/Python → effective OS/time checks → both JDKs/providers → PostgreSQL/database users → pinned CM/JDBC packages → local agent → CM schema → CM HTTP startup → CSDs → bootstrap validation. `RUN_AGENT` runs the corresponding host/agent steps without installing a PostgreSQL server. Neither wrapper invokes the optional add-on.

Java installation and validation belong to step04; there is no Java staging action between preflight and running the appropriate wrapper.

The manager's own agent and supervisord are required. Existing agent UUIDs and database passwords are preserved on reruns. The packaged Python wrapper is checked, not replaced by a symlink. Native psycopg2 is built against host libpq/OpenSSL and checked through the real wrapper; private-library binary wheels are not substituted.

PostgreSQL uses custom PGDATA `/data/1/postgres16`, a traversable parent, correct owner/mode and systemd override. Initialization uses UTF8, local peer administration and SCRAM host authentication. Step06 explicitly sets **`ssl=off`**, binds the configured interfaces/port and inserts loopback/CIDR SCRAM rules ahead of old permissive entries. Outside-CIDR access is rejected. A different-major or nonempty uninitialized PGDATA is rejected.

CM's database utility receives `jdbc:postgresql://<manager>:5432/scm?sslmode=disable`, **without `--ssl`**. The database password uses stdin/redacted output. JDBC is installed and linked at the expected connector path on manager and workers.

CM opens at **`http://<manager>:7180`**. Logs are in `/var/log/cloudera-bootstrap`. A failed step is an error, not permission to continue to later steps. Fix it and rerun within the installation window; bootstrap wrappers can restart services and are not routine health checks for a serving cluster.

## 6. Configure CM and deploy CDP Runtime / ZooKeeper

1. Log in over HTTP7180, apply the license, rotate the bootstrap password and confirm all managed hosts, including the manager. Choose **already-managed hosts** rather than reinstalling agents.
2. Keep Auto-TLS disabled. In CM Administration/Security leave **Use TLS Encryption for Admin Console** (`web_tls`) and **Use TLS Encryption for Agents** (`agent_tls`) disabled. The agent script sets `use_tls=0`.
3. Configure the Management Service. Reports Manager uses `rman/rman` and `RM_DB_PASS`; **Use SSL is disabled**. CM Server itself uses `scm/scm` and `CM_DB_PASS`. Do not interchange them.
4. Add the configured Runtime SP1 repository, download/distribute/activate the locked EL9 CDP parcel.
5. **Before first Runtime service startup**, run on each receiving host:

```bash
source ./EXPORTS
sudo -E bash 14_install_cfm_fips_jars.sh cdp
```

6. Deploy the needed base services, including **ZooKeeper supplied by CDP under CM**. Keep TLS/SSL disabled for **every selected service**, including ZooKeeper client/quorum connections. Keep HDFS HTTP policy `HTTP_ONLY` if deploying HDFS and leave encrypted data-transfer settings disabled. This basic lab does not enable Kerberos.

The Runtime repository is `https://archive.cloudera.com/p/cdh7/7.3.2.10000/parcels/`. The CDP-first step stages release-matched SASL before service startup; it requires no certificates. Other CDP services are optional, not prerequisites for a basic NiFi lab.

## 7. Activate CFM and configure HTTP NiFi / Registry

Add `https://archive.cloudera.com/p/cfm4/4.12.0.10001/redhat9/yum/tars/parcel/`, then download/distribute/activate the exact CFM build locked with the installed CSDs.

On each CFM role host, before first start:

```bash
source ./EXPORTS
sudo -E bash 14_install_cfm_fips_jars.sh cfm
```

For hosts receiving both parcels, `14 ... all` stages/checks both. It installs core providers in TOOLKIT/lib, REGISTRY/lib and NIFI/lib, SASL in NiFi/CDP, and backs up conflicting provider versions outside the classpath.

On the manager generate the HTTP/FIPS settings:

```bash
source ./EXPORTS
sudo -E bash 16_generate_cfm_fips_config.sh
```

This step reads **no certificate, key, CA or DN**. Apply all generated files in `/var/lib/cloudera-bootstrap/cfm-config` to the applicable CM role groups before starting roles:

| File / setting | CM destination / value |
|---|---|
| `nifi-bootstrap.xml` | NiFi staging/bootstrap.conf.xml safety valve, XML property fragments |
| `registry-bootstrap.xml` | Registry staging/bootstrap.conf.xml safety valve, XML property fragments |
| `nifi-properties.xml` | NiFi staging/nifi.properties.xml safety valve |
| `registry-properties.xml` | Registry properties safety valve / equivalent exposed fields |
| `nifi-environment.txt` | NiFi Service Environment safety valve |
| `service-settings.json` | All HTTP, JDK, database and CM/CDP field instructions |
| `actual-csd-fields.json` | Real parameter names/labels from the locked CSDs |
| Both services' Custom Java Home | **`/opt/java/jdk-21`** |
| Enable TLS/SSL | **Disabled**, for NiFi and Registry |

The snippets enable HTTP8080/18080, disable HTTPS and certificate stores, disable secure cluster/site-to-site/ZooKeeper transport, and select no login provider/admin DN. They retain the approved FIPS provider/module flags and NiFi's **NIFI_PBKDF2_AES_GCM_256** sensitive-property encryption. Use the same intended sensitive key on all NiFi nodes and do not rotate an existing key casually. They also retain `HADOOP_SASL_MECHANISM=DIGEST-SHA` and Python3.11.

For Registry, replace embedded H2 with PostgreSQL:

| Field | Value |
|---|---|
| JDBC URL | `jdbc:postgresql://<manager>:5432/nifireg?sslmode=disable` |
| Driver / directory | `org.postgresql.Driver` / `/usr/share/java` |
| Username / password | `REG_DB_USER` / `REG_DB_PASS` |
| Maximum pool connections | 5 unless sized differently |
| SQL debugging | false |

Start the roles in CM. Access **`http://<nifi-host>:8080/nifi/`** and **`http://<registry-host>:18080/nifi-registry/`**. There is no TLS or NiFi/Registry login in this profile.

## 8. Validate the running lab

On applicable hosts:

```bash
source ./EXPORTS
sudo -E bash 15_validate_ready_state.sh bootstrap
sudo -E bash 17_validate_cfm_runtime.sh nifi
# Registry host:
sudo -E bash 17_validate_cfm_runtime.sh registry
# Both local:
sudo -E bash 17_validate_cfm_runtime.sh nifi,registry
```

`15 ... deployed` additionally checks both CDP and CFM libraries and is intended for hosts receiving both parcels. CDP-only hosts use bootstrap plus step14 cdp; CFM-only hosts use bootstrap, step14 cfm and step17.

Step17 checks actual JDK21 JVM paths/flags, effective HTTP/FIPS configuration and real HTTP200 UI responses. It rejects an enabled HTTPS port, certificate store, encrypted NiFi transport or HTTP-to-HTTPS redirect. It neither loads server stores nor performs a TLS handshake. Validate healthy CM/host/ZooKeeper/NiFi membership, Registry persistence through a restart and a representative actual flow.

## Optional later TLS

A user may separately enter the repository's **`TLS/`** folder and follow its independent README/EXPORTS when choosing to add encryption later. That folder can be absent during the complete core installation. The base `RHEL9/EXPORTS` is not used by that workflow.
