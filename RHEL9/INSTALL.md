# RHEL 9.8 FIPS installation — CM, CDP and NiFi 2

This is a **fresh installation** assembled from the RHEL8 FIPS kit and the non-FIPS deployment kit, with both repositories' operational fixes reviewed against the SP1 FIPS instructions. Configuration is in `EXPORTS`; run this directory's scripts, not the RHEL8 scripts. The original RHEL8 implementation is preserved.

## 1. Selected release combination

| Component | Pinned selection | Reason |
|---|---|---|
| OS | **RHEL 9.8 x86_64, OS FIPS enabled** | Requested target; customer reports internal Cloudera confirmation |
| Cloudera Manager | **7.13.2.10000 (SP1)** | Explicit public FIPS 140-3 baseline |
| CDP / Cloudera Base Runtime | **7.3.2.10000 (7.3.2 SP1)** | Matches CM and the supplied SafeLogic SP1 bundle |
| CFM | **4.12.0.10001** | Explicit FIPS 140-3 release; fixes SP1 .10000 packaging defect |
| NiFi / NiFi Registry | **2.6.0**, vendor build from that CFM release | Both CSDs and the parcel must use one build |
| CM / CDP JDK | Upstream **17**, approved vendor patch level | RHEL-modified Java is not selected as the service runtime |
| CFM JDK | Upstream **21**, approved vendor patch level | Both JDKs receive the FIPS provider configuration |
| CM agent / Runtime / NiFi Python | **3.11** in standard OS location | Keep the OS Python and packaged agent wrapper intact |
| PostgreSQL | **16** | Supported CM generation; PG14 is deprecated in Runtime SP1 |

Cloudera's public CFM FIPS procedure currently lists **RHEL 9.6**, not 9.8. The scripts deliberately target **9.8** on the internal confirmation provided by the customer. Retain that internal confirmation with the deployment record. This kit does not represent public 9.8 certification or a live-tested 9.8 deployment. [SOURCES.md](SOURCES.md) records the evidence and the boundary.

CFM's current general download page points at 4.12.0.20000; newer CM/Runtime service packs also exist. They are not silently substituted for the explicit FIPS SP1 combination and the supplied SP1 crypto bundle. This installation is not an in-place NiFi 1, RHEL8, or FIPS 140-2 conversion. Migrate existing flows separately using the applicable Cloudera Flow Migration Tool procedure.

## 2. Host, network and storage preparation

The manager has CM Server, **its own agent and supervisord**, and optionally the independent PostgreSQL server. Workers have CM agent/supervisord and the assigned Runtime/CFM roles. Use the same repository revision, release profile and approved artifacts on every host.

Before running the kit:

1. Provision RHEL **9.8 x86_64** and a stable FQDN on each host. Forward/reverse DNS, CM host identities and certificate SANs must agree. On the manager, `MANAGER_HOST` must equal `hostname -f`; on each worker set `AGENT_HOST` to that worker's `hostname -f`.
2. Provide working RHEL BaseOS/AppStream/CodeReady Builder repositories, PGDG or an approved equivalent, and entitled access to each pinned Cloudera product repository. Proxy and enterprise CA configuration must work for DNF, curl and Python HTTPS. Python's artifact downloader uses verified HTTPS; for an intercepting proxy configure its approved CA with the OS trust configuration and, where required, `SSL_CERT_FILE`. Do not put archive credentials in repository URLs.
3. Mount and size storage before initialization. Default PGDATA is `/data/1/postgres16`. Place CM parcel repository/cache, ZooKeeper data, NiFi flow configuration, FlowFile/content/provenance repositories and service logs on their planned storage. The kit does not format disks or repoint existing NiFi repositories.
4. Provide time synchronization through chrony. Check timezone/time and DNS before requesting certificates.
5. Provide root or noninteractive sudo for the host installer and an administrative SSH route from the manager for one-time Auto-TLS setup.

The requested OS defaults are applied: **firewalld stopped/disabled/masked**, **fapolicyd stopped/disabled/masked**, SELinux persistently disabled and immediately made non-enforcing, THP disabled persistently, swappiness 1, file/process limits 65536 and the source kit's sysctl tuning. Package installation retains diagnostic tools, chrony/rngd, compiler/development dependencies, Python and native PostgreSQL driver prerequisites. This does not disable OS FIPS or switch the crypto policy to LEGACY.

Disabling the host firewall does not open cloud/security-group or network ACL rules. Allow the configured paths:

| Traffic | Default TCP port |
|---|---|
| Browser/API → manager during bootstrap | 7180 |
| Browser/API → manager after Auto-TLS | 7183 |
| Agents → manager heartbeat listener | 7182 |
| Manager → hosts for Auto-TLS SSH | 22 |
| CM, Reports Manager, Registry → database | 5432 |
| NiFi HTTPS | 8443 in this profile |
| Registry HTTPS | 18443 in this profile |
| ZooKeeper client / quorum / election | 2181 / 2888 / 3888; use actual CM configuration |

Also allow the **actual configured NiFi cluster protocol, load balancing and site-to-site ports**, plus any load balancer and selected Runtime service ports. Those are distinct from the HTTPS UI port. Avoid exposing bootstrap HTTP outside the controlled installation network.

On every host check:

```bash
hostname -f
hostname -I
getent hosts "$(hostname -f)"
getent hosts cm01.example.com
lsblk -f
df -h
```

## 3. Enable OS FIPS first

Prefer a RHEL image installed with FIPS enabled, following Red Hat's procedure and the organization's approved module/image baseline. On a clean host that still needs FIPS enabled, perform the Red Hat procedure before generating keys or installing Cloudera; the usual activation sequence is:

```bash
sudo -i
dnf install -y crypto-policies-scripts dracut-fips
fips-mode-setup --enable
sync
reboot
```

After reconnecting:

```bash
cat /etc/redhat-release
fips-mode-setup --check
cat /proc/sys/crypto/fips_enabled
update-crypto-policies --show
grep -w 'fips=1' /proc/cmdline
```

Require RHEL 9.8, kernel FIPS flag **1**, a successful FIPS check and policy **FIPS** or the approved FIPS subprofile. The installer checks these and stops otherwise. An entropy value of **256 is normal on RHEL9**; do not apply RHEL8's higher entropy threshold or old OpenSSL `.hmac` symlink workarounds. OS FIPS activation does not retroactively establish the provenance of keys generated earlier.

## 4. Stage the kit and edit configuration

Use the supplied archive or the branch containing this RHEL9 directory. If applying the handoff patch to the source repository, follow `APPLY_PATCH.txt` from the deliverable first. An unmodified public checkout does not acquire these files until the change is pushed/applied.

```bash
cd /root/cloudera-install-fips/RHEL9
chmod 700 RUN_MANAGER RUN_AGENT ./*.sh tools/*.sh utilities/tls/*.sh
vi EXPORTS
chmod 600 EXPORTS
```

Edit the existing assignments **before derived assignments that reference them**, on each host:

```bash
export CLOUDERA_REPO_USER='your_entitled_archive_user'
export CLOUDERA_REPO_PASS='your_entitled_archive_password'
export MANAGER_HOST='cm01.example.com'
export AGENT_HOST='this-host.example.com'
export ALLOWED_CIDR='10.0.0.0/20'
```

`DB_HOST` defaults to `MANAGER_HOST`; it must match the database certificate's DNS SAN. Set it explicitly for an external database. Keep `DB_SSLMODE=verify-full`.

Replace the lab database, sensitive-property, store and key passwords. The kit enforces at least **14 characters** for FIPS password fields. Auto-TLS/store password fields use letters/numbers to avoid escaping problems in CM/JVM configuration. Database passwords may contain punctuation; they must be single-line. Do not commit deployment credentials, `tls.env`, keys, certificates, generated payloads or artifact caches.

After the initial CM login, rotate the real bootstrap `admin/admin` password in CM, then update `CM_ADMIN_PASSWORD` and the derived Auto-TLS API credentials in `EXPORTS` to match. Editing a file does not rotate the CM account.

The profile supports `POSTGRES_INSTALL_MODE=local` (default) or `external`. External mode installs a client and leaves server provisioning, TLS/SCRAM enforcement and database/user creation to the DBA. It does not initialize or alter that server. Required database pairs are in section 7.

## 5. Supply complete upstream JDK 17 and JDK 21 installations

Use supported, approved upstream JDK distributions at their approved patch levels, for example the supported Azul Zulu distribution. Install **JDKs**, not JREs: `java`, `jar` and `keytool` are required.

Either pre-stage complete homes:

```text
/opt/java/jdk-17
/opt/java/jdk-21
```

or set vendor archive paths and **trusted vendor SHA256** values in `EXPORTS`:

```bash
export JAVA_ARCHIVE_FILE='/root/downloads/approved-jdk17.tar.gz'
export JAVA_ARCHIVE_SHA256='actual_vendor_SHA256_here'
export CFM_JAVA_ARCHIVE_FILE='/root/downloads/approved-jdk21.tar.gz'
export CFM_JAVA_ARCHIVE_SHA256='actual_vendor_SHA256_here'
```

The installer verifies archive hashes, checks unsafe paths/links, extracts a single top-level JDK directory and reuses an existing home. JDK parents must be traversable by service users; executables must be usable on the mounted filesystem. No checksum or proprietary JDK patch version is fabricated by this repository.

CM/CDP use `/opt/java/jdk-17`. NiFi **and Registry** must have their CM **Custom Java Home** set to `/opt/java/jdk-21`; changing the shell's Java alternative is insufficient. An incidental Java RPM dependency must not replace those explicit service homes. Do not point the CM agent Python wrapper at another interpreter or change `/usr/bin/python3`; Python 3.11 is installed alongside the OS interpreter and the packaged wrapper is checked.

## 6. Supply the exact SafeLogic SP1 bundle

Stage the actual tarball on each host and set `FIPS_BUNDLE_ARCHIVE` to its path. Default:

```text
/root/Cloudera-Base-on-premise-7.3.2-SP1-Safelogic-FIPS-Modules-07282026.tar.gz
```

The screenshot identifies these files, each with its original `.sha256` sidecar:

| JAR | Installation use |
|---|---|
| `ccj-4.0.0-fips.jar` | CCJ provider; both JDKs and CFM libraries |
| `bctls-2.0.17.1.jar` | BCJSSE provider; both JDKs and CFM libraries |
| `bcutil-2.0.1.jar` | Provider support; module path, CM classpath and CFM libraries |
| `bcpkix-2.0.6.jar` | Verify and retain with the supplied bundle |
| `bcmail-2.0.4.jar` | Verify and retain with the supplied bundle |
| `bcpg-2.0.6.jar` | Verify and retain with the supplied bundle |
| `bcpqc-8.5.jar` | Verify and retain with the supplied bundle |

Only the three core JARs and release-matched Cloudera SASL JAR go in `/opt/cloudera/fips`, which is the shared JVM module path. The other four remain available in the verified bundle; they are not indiscriminately added to every classpath or used to replace unrelated parcel dependencies. Library presence does not enable every algorithm it contains.

`00_prepare_artifacts.sh` validates all seven JARs and their supplied sidecars, tolerates digest-only/GNU/BSD checksum formats, rejects unsafe/duplicate tar members and does not overwrite different existing artifacts. Alternatively, pre-stage the seven JARs and sidecars directly in:

```text
/opt/cloudera/fips-jars/cdp-7.3.2.10000/
```

The screenshot is not the binary bundle and contains no digest values. Supply the original files; do not create expected digests from an untrusted download. If a trusted whole-tarball SHA256 was also supplied, set `FIPS_BUNDLE_SHA256`.

**Cloudera SASL is separate and mandatory.** It is absent from the screenshot. The artifact preparer visits the pinned CDP Maven location, resolves the sole matching `sasl-sha256aes-0.1.0.7.3.2.10000-<build>.jar`, checks the provider class and records its SHA256. If the archive publishes a `.sha256`, it is checked; otherwise the lock explicitly records that authenticity came from verified authenticated HTTPS and the hash was recorded locally. `FIPS_SASL_SHA256` can add an independently supplied expected digest. Multiple internal builds cause a stop: set the exact `FIPS_SASL_JAR` from your entitled listing or stage it with its trusted sidecar. Do not reuse a 7.3.1, SP2 or CCJ3 SASL/provider set.

The same preparation resolves the **EL9 CDP and CFM manifests** and downloads both matching CSDs before host package/OS changes. The CFM build is discovered, never guessed. A JSON lock in `/var/lib/cloudera-bootstrap/rhel98-fips140-3-sp1/artifacts.json` records versions, names, hashes and provenance. Reruns reject release artifact drift. Use the same lock/inputs on all hosts; keep the lock with installation records. The kit deliberately does not embed a fabricated SP1 build number.

## 7. Prepare PostgreSQL and TLS inputs

For local mode, obtain a separate server key/certificate for `DB_HOST` and its CA chain. Generate the key and CSR on the prepared FIPS manager:

```bash
source ./EXPORTS
sudo -E bash tools/prepare_postgres_tls.sh request
```

Send **only the CSR** to the CA. The key remains local. Place the returned server leaf followed by issuing intermediates in `server.crt`; put trusted root/intermediate CA certificates in `ca-chain.pem`:

```text
/opt/cloudera/postgres-tls/server.key        # 0600, unencrypted for unattended PostgreSQL
/opt/cloudera/postgres-tls/server.crt
/opt/cloudera/postgres-tls/ca-chain.pem
```

```bash
sudo -E bash tools/prepare_postgres_tls.sh validate
```

Distribute **only the public CA chain** to `DB_CLIENT_CA_FILE` on every database client/worker. Its parent must be traversable and the CA readable by Registry/Reports Manager. Do not distribute the database server private key.

The installer uses a traversable PGDATA parent, systemd PGDATA override, UTF8 database initialization, local peer administration, TLS-only TCP and **SCRAM-SHA-256**. Non-TLS rules and TLS allow rules precede existing pg_hba entries, including IPv4/IPv6 loopback; TLS access outside the allowed networks is rejected. Existing databases and passwords are preserved unless explicit password reset is configured. A data directory from another PostgreSQL major, or a nonempty uninitialized directory, is rejected.

| Consumer | Database / user | Password source |
|---|---|---|
| CM Server | `scm` / `scm` | `CM_DB_PASS` |
| Reports Manager | `rman` / `rman` | `RM_DB_PASS` |
| NiFi Registry | `nifireg` / `nifireg` | `REG_DB_PASS` |
| Optional Hue / Hive / Ranger | Configurable in `EXPORTS` | Created only with `CREATE_EXTRA_DBS=true` |

The psycopg2 Host Inspector fix is retained and enabled by default. It builds the pinned package from source against the host's PostgreSQL/OpenSSL libraries, validates its native linkage and checks import through the actual agent wrapper after CM installation. Do not substitute a `psycopg2-binary` wheel that brings private native crypto libraries. For an intentionally NiFi-only install with no Hue inspector requirement, the source-build feature can be disabled in configuration; it is not silently ignored on failure.

The PostgreSQL JDBC RPM is installed on manager **and workers**. Its real driver is linked at CM's expected `postgresql-connector-java.jar` path and checked for `org/postgresql/Driver.class`.

## 8. Bootstrap manager and every worker

On the manager:

```bash
cd /root/cloudera-install-fips/RHEL9
source ./EXPORTS
sudo -E ./RUN_MANAGER
```

The wrapper verifies inputs and entitled artifacts first, then runs repositories → OS controls → packages/Python → OS validation → both JDKs/FIPS providers → PostgreSQL/TLS/databases → pinned CM packages → local agent → CM schema → CM startup → CSDs → bootstrap validation. Disabling fapolicyd precedes source builds and loading new provider libraries.

On **each worker**, with its own `AGENT_HOST` and the shared profile/approved inputs:

```bash
cd /root/cloudera-install-fips/RHEL9
source ./EXPORTS
sudo -E ./RUN_AGENT
```

Workers do not install a PostgreSQL server. Manager and worker readiness requires the agent and supervisord; the manager's own agent is essential. CM's versioned packages are checked after installation. The packaged Python wrapper must resolve the configured 3.11 runtime. Registered host identity files are preserved; the kit does not reset UUIDs on routine reruns.

The JDK provider check runs **both Java 17 and Java 21**, then repeats as `cloudera-scm` after the account exists. It checks provider order, CCJ's actual approved-only state, BCJSSE, Cloudera SASL, BCFKS and AES-GCM. Both agent and supervisord receive explicit systemd Java/FIPS environments. CM receives FIPS and FIPS-SASL flags, BCUTIL classpath, actual provider module names and BCFKS trust settings. The doubled `com.cloudera.cloudera.cmf...` property prefix follows Cloudera's documented option name.

Bootstrap success is not NiFi deployment completion. Logs are in `/var/log/cloudera-bootstrap`. If a step fails, fix its reported cause and rerun the step/wrapper while services remain in the installation window. Do not run bootstrap wrappers against a serving cluster as a routine health check: they can restart agent/supervisord/CM. Use the validation scripts instead.

## 9. Register hosts, rotate CM credentials and enable Auto-TLS

Open CM on port 7180. Apply the license, rotate the CM administrator password and update `EXPORTS`. Confirm all expected managed hosts, **including the manager**, are present. Use already-managed hosts; do not reinstall older agents through the wizard.

Enable host Auto-TLS before the first Runtime/CFM service deployment. Follow [utilities/tls/README.md](utilities/tls/README.md), including the full host inventory, CSR handoff and return validation. The default customer-CA workflow is:

```bash
cd utilities/tls
cp tls.env.example tls.env
# Edit tls.env and hosts.csv; include every manager/worker hostname and required SAN.
sudo -E bash run_autotls.sh prepare-csrs
# Send only the generated CSR package; place returned leaves and ordered CA chain.
sudo -E bash run_autotls.sh customer
```

Node certificates require **serverAuth and clientAuth**, correct SANs, distinct host identities, valid dates and a correctly ordered CA chain. Store/key passwords are at least 14 characters. The local builder creates BCFKS directly via CCJ; it does not create an intermediate PKCS12 private-key store. Encrypted and unencrypted customer PEM keys are supported only when the configured mode matches them. Per-host encrypted-key password files use the required `hosts-key-store/<hostname>/cm-auto-host_key.pw` path.

After the local dry run passes, edit the TLS configuration for the live operation:

```bash
export AUTO_TLS_DRY_RUN='false'
export AUTO_TLS_CONFIRM_LIVE='ENABLE-AUTOTLS'
export AUTO_TLS_CONFIRM_POST_RESTART='RESTART-AUTOTLS'
```

Then, from the TLS directory:

```bash
sudo -E bash run_autotls.sh enable
sudo -E bash run_autotls.sh post-restart
```

The live workflow sets up/validates the dedicated SSH account, checks service-user file access, submits `generateCmca` and polls **terminal command success**. Post-restart refreshes CM's public-roots + DB-CA + cluster-CA BCFKS truststore, restarts CM, verifies trusted HTTPS and restarts agents. The fresh-install profile leaves `AUTO_TLS_POST_RESTART_MANAGEMENT_SERVICE=false` because the Management Service is created afterward. Existing cluster restart switches apply only to clusters that exist.

After success, update the main `EXPORTS` on applicable hosts:

```bash
export CM_RUNTIME_PROTOCOL='https'
export CM_RUNTIME_PORT='7183'
export CM_RUNTIME_CA_FILE='/path/to/the/trusted/cluster-ca-chain.pem'
```

A CM-managed filename ending `.jks` can contain **BCFKS**. Validate the format rather than renaming it or setting the type from the extension. The shared runtime truststore contains **public CA certificates only** and is readable by NiFi/Registry service users. Private keys/password files remain restricted.

## 10. Create the Management Service and deploy Runtime

Configure the Cloudera Management Service in CM. Set Reports Manager's database host/port/name/user/password from `EXPORTS`, enable TLS and server certificate verification, and provide its readable DB CA / the supported SSL fields for this CM release. Do not enter the CM Server's database password into Reports Manager's screen. Start and verify the Management Service after its database TLS settings are complete.

For Runtime, use the configured SP1 parcel repository:

```text
https://archive.cloudera.com/p/cdh7/7.3.2.10000/parcels/
```

Select already-managed hosts. Download/distribute/activate the **locked EL9 CDP parcel** shown in `artifacts.json`. **Pause the wizard before its first service startup** and run on every receiving Runtime host:

```bash
cd /root/cloudera-install-fips/RHEL9
source ./EXPORTS
sudo -E bash 14_install_cfm_fips_jars.sh cdp
```

This verifies the CDH activation symlink against the locked SP1 parcel and copies its SASL provider to `CDH/jars` and `CDH/lib/hadoop` before services first use it. Then finish deploying required Runtime services, including **ZooKeeper from CDP under CM**. Do not install an unrelated system ZooKeeper.

Only the selected services are in scope. If adding Kerberos, Ranger/KMS, HDFS TDE, LDAP or additional databases, follow those products' SP1 FIPS procedures, including the optional database setup. They are not prerequisites invented for a basic NiFi/ZooKeeper installation.

## 11. Activate CFM and stage FIPS libraries

In CM add:

```text
https://archive.cloudera.com/p/cfm4/4.12.0.10001/redhat9/yum/tars/parcel/
```

Supply entitled archive credentials through CM's protected repository settings. Download/distribute/activate the exact CFM parcel in `artifacts.json`; the installed NiFi/Registry CSDs already match its build.

Before adding/starting NiFi or Registry, run on every CFM role host:

```bash
source ./EXPORTS
sudo -E bash 14_install_cfm_fips_jars.sh cfm
```

For hosts receiving both parcels, `14_install_cfm_fips_jars.sh all` checks/stages both. The script requires real activated parcel directories, then copies CCJ/BCTLS/BCUTIL to **TOOLKIT/lib, REGISTRY/lib and NIFI/lib**, and SASL to **NIFI/lib**. Conflicting old versions of those library families are backed up outside the classpath. It does not remove unrelated CSDs or other parcel libraries. Run this again for a newly activated parcel after any reviewed update, with services stopped.

## 12. Apply NiFi / Registry settings before first start

Set `NIFI_INITIAL_ADMIN_IDENTITY` and `REGISTRY_INITIAL_ADMIN_IDENTITY` in `EXPORTS` to the **actual identities** for the client certificate or configured authentication provider. For certificate authentication, enter the full unmapped certificate DN; NiFi also applies configured identity mappings to initial-admin and node-identity values. Keep each host/node identity unique. Set `NIFI_NODE_HOSTS` to the space-separated FQDNs of the actual NiFi nodes. The generator reads the returned public node certificates, using Java's RFC2253 identity representation, and derives their common DN prefix/suffix. It leaves the suffix empty for CN-only certificates and uses the real suffix when certificates contain organization fields. It rejects inconsistent templates; do not append `, OU=NIFI` arbitrarily. Review `node-identities.json` and verify the generated authorizers before starting.

On **every CFM role host**, refresh local public CA trust after Auto-TLS:

```bash
source ./EXPORTS
sudo -E bash 16_generate_cfm_fips_config.sh trust
```

On the **manager**, where the returned public certificates/inventory are available, generate the common CM settings:

```bash
sudo -E bash 16_generate_cfm_fips_config.sh render
```

This adds the installed cluster CA to each host's runtime BCFKS truststore and creates private configuration under `/var/lib/cloudera-bootstrap/cfm-config`. `CM_CLUSTER_CA_FILE` defaults to the agent's `cm-auto-global_cacerts.pem`; set the actual trusted CA PEM path if different. All hosts need the same intended trust password and NiFi sensitive-properties key.

In CM's Add Service workflow, configure all applicable role groups before completing first startup:

| Generated file / field | CM destination |
|---|---|
| `nifi-bootstrap.xml` | NiFi Node Advanced Configuration Snippet for **staging/bootstrap.conf.xml**, XML view |
| `registry-bootstrap.xml` | Registry Advanced Configuration Snippet for **staging/bootstrap.conf.xml**, XML view |
| `nifi-properties.xml` | NiFi Node Advanced Configuration Snippet for **staging/nifi.properties.xml**, XML view |
| `registry-properties.xml` | Registry properties safety valve / equivalent exposed fields |
| `nifi-environment.txt` | NiFi **Service Environment** Advanced Configuration Snippet |
| `service-settings.json` | JDK home, admin identities, DB/driver settings and remaining field instructions |
| `node-identities.json` | Actual unmapped certificate DNs and the derived generated-node DN template |
| `actual-csd-fields.json` | Real API parameter names/labels extracted from the exact installed CSDs |

Apply snippets as XML **property fragments**, preserving unrelated entries and eliminating duplicate `java.arg` properties. Do not substitute a properties file into the XML-view field. `actual-csd-fields.json` helps identify release-specific field names without guessed CM API keys.

Required resulting configuration:

- **Both CFM services' Custom Java Home = `/opt/java/jdk-21`.** CM/CDP remain on Java 17.
- Both CFM bootstrap files include the FIPS module path, modules/exports, both approved-only flags, **GCM cipher enablement**, and explicit BCFKS JVM truststore path/type/password.
- NiFi's algorithm is **NIFI_PBKDF2_AES_GCM_256**, with one intended sensitive key across its nodes. Never rotate it casually after flows have been created.
- Both service key/truststore types are **BCFKS**; use CM's Auto-TLS paths and their real passwords. Registry's key/trust manager algorithm is **PKIX**.
- NiFi service environment includes **HADOOP_SASL_MECHANISM=DIGEST-SHA**. NiFi Python command points at **`/usr/bin/python3.11`**.
- HTTPS hostnames match certificate SANs; ports are 8443 / 18443 unless changed in configuration. Plain HTTP is disabled. Configure the intended authenticated administrator; the generated NiFi settings disable anonymous access.

For Registry, replace embedded H2 with PostgreSQL:

| CM Registry field | Value |
|---|---|
| JDBC URL | `REGISTRY_DB_JDBC_URL` from `EXPORTS`: manager FQDN, `nifireg`, `sslmode=verify-full`, explicit CA PEM |
| JDBC driver | `org.postgresql.Driver` |
| Driver directory | `/usr/share/java` |
| Database username / password | `REG_DB_USER` / `REG_DB_PASS` |
| Maximum pool connections | 5, unless sized differently |
| Database SQL debugging | false |

Ensure the Registry service user can read the DB CA and traverse its parents. Confirm the connection from the Registry host before first start, using the configured PG client and environment rather than embedding a password in shell history:

```bash
PGPASSWORD="$REG_DB_PASS" PGSSLMODE=verify-full PGSSLROOTCERT="$DB_CLIENT_CA_FILE" \
  "$PG_BIN_DIR/psql" -h "$DB_HOST" -p "$DB_PORT" -U "$REG_DB_USER" -d "$REG_DB_NAME" \
  -c 'select current_database(), current_user;'
```

Complete the CM service startup workflow. If provider environment changes require restarting agent/supervisord, stop affected roles first and use CM's supported restart sequence; do not terminate supervisord under running flows. Do not delete `users.xml` or `authorizations.xml` on a deployed service to repair a DN mismatch. Correct the identity/mapping configuration and use the supported authorization procedure.

## 13. Validate the complete end state

On the manager and applicable parcel hosts:

```bash
source ./EXPORTS
sudo -E bash 15_validate_ready_state.sh deployed
```

On each actual CFM role host:

```bash
sudo -E bash 17_validate_cfm_runtime.sh nifi
# Or on the Registry host:
sudo -E bash 17_validate_cfm_runtime.sh registry
# When both roles are local:
sudo -E bash 17_validate_cfm_runtime.sh nifi,registry
```

Step 17 checks the effective CM-generated configuration, actual running **JDK 21** executable and FIPS flags, HTTPS-only settings, sensitive algorithm/key, and actual BCFKS store loading. It then performs a real **BCJSSE mutual TLS handshake with hostname verification** using the service stores. A listening port or a running PID alone is insufficient.

Also verify the operational acceptance items in [VALIDATION.md](VALIDATION.md): CM host health; ZooKeeper membership; NiFi cluster membership; authenticated browser/API access; Registry PostgreSQL persistence across restart; a representative flow using the actual external JDBC/LDAP/Hadoop/TLS endpoints; and no provider/cipher/store errors in logs. A FIPS-configured server does not make arbitrary processor-specific TLS contexts or dataflows compliant automatically.

`15 ... deployed` checks both CFM and CDP staging and is intended for hosts receiving both parcels. For a CDP-only host use bootstrap readiness plus the successful `14 ... cdp` result; for a CFM-only host use bootstrap readiness, `14 ... cfm` and step 17. The manager need not receive unused parcels.

## 14. Script map and recovery

| Script | Purpose |
|---|---|
| `00_prepare_artifacts.sh manager\|agent` | Verify staged inputs; resolve/lock entitled artifacts before OS changes |
| `00_check_connectivity.sh manager\|agent` | OS FIPS, required DNS, host identity, repositories and diagnostic checks |
| `01_bootstrap_repos.sh` | DNF plugins, CodeReady, PGDG signing key/repository, optional EPEL |
| `03_configure_os.sh` → `02_install_common_packages.sh` → `03_validate_os.sh` | Requested OS controls first; packages/Python/native adapter; effective OS/time checks |
| `04_install_java_fips_runtime.sh` | Upstream Java 17/21 and approved provider/module configuration |
| `05` → `06` → `07` | PGDATA/init → TLS/SCRAM networking/start → service databases/users |
| `08` → `09` → `10` | CM repository → version-pinned CM/JDBC → local agent |
| `11` → `12` → `13` | TLS CM DB preparation → CM startup → matching CSD install |
| `14_install_cfm_fips_jars.sh cdp\|cfm\|all` | After activation, before first affected service start |
| `15_validate_ready_state.sh bootstrap\|deployed` | Readiness appropriate to installation phase |
| `16_generate_cfm_fips_config.sh trust\|render` | Refresh per-host CA trust; generate common service settings on the manager |
| `17_validate_cfm_runtime.sh nifi\|registry\|nifi,registry` | Effective live service and TLS validation |

Keep logs, `artifacts.json`, internal RHEL9.8 confirmation, approved input digests, CM effective configuration and acceptance results with the deployment record. Private configuration/backups must remain restricted. Source revisions and every retained/adapted deployment lesson are listed in [MERGE_NOTES.md](MERGE_NOTES.md).

Offline repository checks are available through `tools/run_static_validation.sh` and `utilities/tls/tests/run_all_tests.sh` on a development host with Python, OpenSSL and Java/keytool. They use synthetic/non-FIPS fixtures; the actual CCJ/BCFKS and RHEL9.8 checks must run on the target hosts with the supplied binaries.
