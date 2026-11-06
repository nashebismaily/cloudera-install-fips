# HTTP rebuild validation — 2026-11-06

| Check | Result |
|---|---|
| Core installer regression suite | **32 tests passed** |
| Core shell / Python / references / configuration audit | Passed |
| Core independent of optional TLS directory | Real manager/agent preflight and step16 run in a core-only copy with no TLS folder |
| PostgreSQL | Non-SSL SCRAM configuration, rule precedence and idempotency checked |
| CM database utility | Non-SSL URL, no SSL switch and redacted stdin password checked |
| Agent configuration | General-section `use_tls=0`, preservation of unrelated sections and rerun stability checked |
| NiFi / Registry | Generated HTTP settings, actual HTTP200 probes with fixture JVMs, enabled-HTTPS/missing-FIPS rejection and HTTPS-redirect rejection checked |
| Optional module | Seven portable TLS suites, two certificate-DN cases and standalone/idempotent add-on defaults checked separately |
| Java helper sources | Compiled separately for core/add-on with Java21 source/target17 settings |
| Java preflight regression | Real manager and agent preflight both succeed with no JDK homes or Java archives in an isolated host |
| Automatic Java installation | Real upstream Temurin17.0.21 and21.0.13 archives downloaded, vendor SHA256-verified, safely extracted and executed in temporary homes; second run reused both homes |
| Java failure cases | Wrong download/local checksum, wrong architecture/early access, unsafe paths/links and HTTPS downgrade rejected; offline local-archive overrides verified |
| Original RHEL8 files | All49 preserved byte-for-byte |

Artifact tests retain safe seven-JAR extraction/sidecars, manifest OS/build filtering, matching CSDs/SASL, checksum provenance, deployment-lock drift rejection, full provider distribution, CDP-first staging, versioned RPM/JDBC checks, OS controls, provider-patch idempotency and automatic vendor public-root collection. No proprietary binaries or site credentials are bundled.

Reproduce the independent core checks:

```bash
cd RHEL9
bash tools/run_static_validation.sh
```

Run the optional module's checks separately if desired:

```bash
cd TLS
bash tools/run_static_validation.sh
bash tests/run_all_tests.sh
```

Root-gated installer cases ran in an isolated user namespace with fake host commands/paths. This development environment is Debian/Java21, not a live RHEL9.8 FIPS Cloudera cluster. Offline fixtures do not prove actual CCJ cryptographic-module validation, vendor support or a completed target deployment.

## Target-host acceptance

1. RHEL9.8 x86_64, internal compatibility record, OS FIPS flag/policy and synchronized time; requested OS tuning/control state.
2. Actual approved JDK17/21 and SafeLogic bundle/sidecars; resolved entitled CDP/CFM/CSD/SASL lock matches on each host.
3. Both JDKs' actual CCJ approved-only state, BCJSSE/SASL, BCFKS and AES-GCM, including service-user loading.
4. PG16 custom PGDATA, `SHOW ssl` off, SCRAM roles and working plain database connections from CM/Reports/Registry hosts.
5. CM HTTP7180, unencrypted agent heartbeats, correct RPM/Python/JDBC/native-adapter state, healthy manager and workers.
6. CDP-first SASL staging and healthy CM-managed ZooKeeper; service/agent TLS and Auto-TLS remain disabled.
7. Correct CFM libraries, Java21 homes, HTTP-only settings, sensitive algorithm/key and DIGEST-SHA environment on all role groups.
8. Step17 succeeds on each actual NiFi/Registry host; browser/API HTTP access, cluster membership and Registry PostgreSQL persistence work through restart.
9. A representative real dataflow and its intended external dependencies work; no unexpected certificate/provider/database requirements remain in the basic installation.

Optional later TLS acceptance belongs to the separate module's workflow. It is not a condition for completing this HTTP lab installation.
