# Deployment lessons merged into RHEL9

Inputs are the exact commits in [SOURCES.md](SOURCES.md), including both main READMEs, every numbered host script, wrappers, configuration/common helpers, TLS utilities/tests and the non-FIPS `utilities.zip`. The non-FIPS ZIP's operational TLS files match its checked-out utility files; macOS metadata and empty backup folders do not add installation steps.

| Source lesson / function | RHEL9 treatment |
|---|---|
| FIPS enabled before Cloudera / key creation | OS provisioning instructions and hard preflight checks for RHEL9.8, kernel flag, FIPS check and crypto policy |
| RHEL8 CCJ3/BCTLS/JDK11 behavior | Replaced by the supplied SP1 CCJ4/BCTLS/BCUTIL set and upstream JDK17 + JDK21; both JDKs validated |
| RHEL8 entropy / OpenSSL workarounds | RHEL9's 256 entropy ceiling recognized; obsolete `.hmac` symlinks and legacy crypto policy changes not carried forward |
| fapolicyd blocked SafeLogic loading | Stop, disable and mask before source builds/provider loading; verify disabled state and service-user provider access |
| Non-FIPS firewall deployment prerequisite | firewalld stop/disable/mask enabled by default; network/security-group ports documented |
| SELinux deployment mode | Persistent disabled default retained; immediate non-enforcing state; configurable modes retained |
| THP / swappiness / file/process tuning | Persistent THP service, both THP controls, same sysctls and systemd/security limits, effective-state validation |
| Common tools / CodeReady / external repos | Union of relevant OS diagnostic/build/runtime dependencies; RHEL9 package names; explicit CRB/PGDG/EPEL choices |
| PGDG signing key failure | Import the PGDG key before repo RPM installation; signatures/TLS remain enabled |
| CM and NiFi need separate Java versions | Stable upstream homes; CM/CDP17 and both CFM services21; explicit CM service settings, not a global alternative switch |
| Non-FIPS Python3.9 wrapper symlink | Corrected for CM7.13.2: install standard-location3.11 first, preserve OS Python and the packaged CM wrapper, check actual interpreter |
| psycopg2 missing specifically in agent environment | Retained, checked through real wrapper; source build against host libpq/OpenSSL replaces private-library binary wheels |
| Custom PostgreSQL data path / inaccessible parent | Configurable PGDATA, traversable parent check, owner/mode, systemd/sysconfig override, SELinux labeling where available, major-version/nonempty-directory guards |
| PostgreSQL listening only on loopback | Configured bind/port; required network CIDR and both loopbacks; effective TLS/SCRAM configuration |
| FIPS rejects MD5 database authentication | SCRAM-SHA-256 password storage/auth; TLS-only TCP; managed rules precede old permissive entries; out-of-CIDR rejection |
| Database role creation and safe reruns | All CM/Reports/Registry pairs; optional Hue/Hive/Ranger; SQL-quoted identifiers/passwords; existing passwords preserved by default |
| Registry driver missing on worker | JDBC installed on manager and workers; correct CM connector filename, driver-class validation and Registry driver directory |
| CM database prep utility / JDBC TLS | TLS URL and verified BCFKS CA trust, password on stdin with output redaction, correct database hostname/port |
| CM's own local agent required | Installed/configured on manager; agent and supervisord checked on every managed host |
| Live-install host header workaround | Configurable CM host-header setting retained with the prior working value |
| Accidental host identity resets on rerun | UUID/cm_guid preserved; explicit repair flag only; no default reset |
| Mixed CFM CSDs / wrong parcel | Resolve matching EL9 manifest/build, validate both CSDs before installing, keep other services' CSDs, back up old NiFi descriptors |
| JAR staging missed Toolkit / Registry / NiFi | Core providers copied to all three CFM lib directories; SASL to NiFi and both CDP Hadoop destinations |
| SASL needed before first Runtime start | Separate `14 ... cdp` after CDP activation; first-start pause documented before deploying Runtime/ZooKeeper |
| Default Java cacerts unavailable in FIPS | Explicit merged BCFKS store containing approved upstream public roots, DB CA and cluster CA; public certificates readable by each service user |
| Auto-TLS must include every managed hostname | Reviewed/generated inventory, SANs and CM-host inclusion; full prerequisite checks before live submission |
| Customer CA and test CA workflows | Customer default with CSR-only handoff, return/chain/key validation; isolated test-CA workflow retained |
| Encrypted / unencrypted customer keys | Exact mode/password validation; required per-host password filenames; stale password-file removal for unencrypted mode |
| Store type mismatch / KeyManagerFactory failures | Direct CCJ BCFKS store builder; real store loading; explicit Registry PKIX algorithms; no default PKCS12/JKS private stores |
| Auto-TLS API acceptance mistaken for completion | Poll terminal success by command ID; verify trusted HTTPS after restart; separate fresh-install Management Service timing |
| Browser cipher mismatch | GCM allowed in both JDK environments and both CFM bootstrap snippets; live BCJSSE handshake validation |
| NiFi sensitive encryption / Hadoop auth | PBKDF2/AES-GCM algorithm and intended shared key; DIGEST-SHA service environment and release-matched SASL |
| Non-FIPS generated node DN suffix caused collision | Real Java certificate DNs drive the prefix/suffix; CN-only certificates retain an empty suffix; inconsistent templates rejected; no automatic deletion of users/authorizations |
| Non-FIPS anonymous bootstrap example | Explicit authenticated administrator identities required for the new service configuration; no anonymous-admin default |
| ZooKeeper placement | CDP/CM-managed ZooKeeper; no independent OS package deployment |
| Installer warning through required failures | Mandatory artifacts/packages/service readiness fail the step; bootstrap and deployed validations separated |

The OS-first ordering intentionally runs numbered step03 before step02: disabling fapolicyd precedes building the native PostgreSQL adapter. Common package installation then precedes effective OS/time validation.

All 49 original RHEL8 tracked implementation files are preserved byte-for-byte. Root README gains RHEL9 navigation and labels the existing RHEL8 instructions. The non-FIPS repository is a read-only input; its files are not modified.
