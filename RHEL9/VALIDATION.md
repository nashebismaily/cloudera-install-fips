# Validation record — RHEL9.8 FIPS kit

Review date: **2026-11-06**. Source commits and version evidence are in [SOURCES.md](SOURCES.md).

## Completed offline checks

| Check | Result |
|---|---|
| Original RHEL8 implementation | All 49 original tracked files preserved byte-for-byte |
| Shell/config/wrapper syntax | Passed |
| Standalone/embedded Python and wrapper references | Passed |
| Configurability audit | Passed |
| Installer regression suite | **22 tests passed**, including root-gated host scripts inside an isolated user namespace |
| Portable TLS suite | **All 7 suites passed** |
| Java helpers | Compiled with Java21 using source/target17 settings; public-CA collection exercised with Java21 |
| No deployment binaries/credentials/private material | Included source only; approved binaries and site inputs remain external |

The installer tests exercise the actual seven-file bundle/sidecar formats, safe extraction and no-overwrite behavior, manifest OS/version filtering and ambiguous-build rejection, SASL checksum provenance, complete locked resolution/rerun drift rejection, CDP-first SASL staging, all CFM provider destinations, displaced-provider backup, preservation of unrelated CSDs, validation before CSD replacement, versioned CM packages, JDBC driver linkage, effective PostgreSQL TLS/SCRAM rule ordering and reruns, wrong-hostname rejection, OS service disabling/masking, CM FIPS/SASL/trust persistence, provider-file idempotency, merged public CA roots and invalid runtime-setting rejection and actual-DN template handling and a real Java certificate-DN round trip.

The TLS suites cover inventory generation; sandboxed SSH account setup/reruns; two-host encrypted keys, CSR package privacy and complete network-blocked dry-run orchestration; wrong/missing certificates, SANs and passwords; customer chains and chain-order rejection; externally generated unencrypted keys; and configured/actual key-mode mismatches. Portable tests deliberately use a non-FIPS offline store profile that cannot submit a live enablement request.

Reproduce on a development machine with Bash, Python3.11, OpenSSL and Java/keytool:

```bash
cd RHEL9
bash tools/run_static_validation.sh
bash utilities/tls/tests/run_all_tests.sh
```

Root-only fixture cases need root or an isolated user namespace. This review used `unshare --user --map-root-user` for those cases; all production commands were replaced with isolated paths/mocks. There was no actual CM/PG service installation on the development machine.

## Required live acceptance on the target hosts

This environment is Debian with Java21; it is **not RHEL9.8 in FIPS mode**. It has no customer archive entitlement, proprietary SafeLogic/SASL binaries, actual vendor JDK17 installation, enterprise certificate returns or running Cloudera cluster. Offline tests do not prove certification or a one-shot production installation.

Record actual evidence for these items while following [INSTALL.md](INSTALL.md):

1. RHEL9.8 x86_64 image, internal Cloudera compatibility confirmation, kernel flag1, successful OS FIPS check, approved FIPS crypto policy; chrony synchronized; firewalld/fapolicyd disabled as requested; THP/tuning effective.
2. Original bundle digests, real entitled parcel/CSD/SASL lock, same inputs on all hosts; supported upstream JDK17/21 vendor builds and trusted hashes.
3. Step04 and post-package provider checks under root **and cloudera-scm**, for both JDKs: expected module names/order, CCJ actual approved-only mode, BCJSSE, SASL, BCFKS and AES-GCM.
4. PostgreSQL16 custom PGDATA and correct owner/traversal; TLS-only TCP, SCRAM, successful verified connections from CM, Reports Manager and Registry hosts. Existing passwords/data preserved on reruns.
5. Exact CM RPM versions, intact packaged Python wrapper reporting3.11, native psycopg2 import/linkage and JDBC driver class; healthy manager/local agent and remote agents/supervisord.
6. Auto-TLS real customer inventory/certificates, SANs, both EKUs, ordered CA chain, matching encrypted-key mode/password files, real BCFKS stores; terminal API command success followed by trusted manager HTTPS and healthy agent heartbeats.
7. Locked CDP activation and step14 cdp **before first Runtime startup**; healthy CM-managed ZooKeeper and selected Runtime services; correct Reports Manager DB TLS settings.
8. Locked CFM activation, core libraries in all three lib directories, SASL in NiFi/CDP, Java21 and every generated FIPS/bootstrap/property/environment setting applied to all role groups.
9. Step17 on every NiFi/Registry host: running executable/flags, real BCFKS key/trust stores, HTTPS-only configuration and a successful BCJSSE mutual TLS handshake with hostname verification.
10. Authenticated browser/API access, unique intended user/node identities and healthy NiFi cluster membership; Registry writes to PostgreSQL and retains buckets/flows after restart; a representative real dataflow and every actual external integration pass. Review logs for provider, cipher, truststore, certificate, SASL or database errors.

Keep the accepted configuration, versions, logs and test evidence. The repository is an installation implementation/runbook; it cannot supply a module validation certificate or replace acceptance against the actual approved image and binaries.
