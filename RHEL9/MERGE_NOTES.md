# Merge and HTTP rebuild notes

This rebuild separates **cryptographic-provider preparation** from **transport encryption**. The previous mandatory CA-file failure came from a TLS-dependent path added to the first merge. That path is removed throughout the standard deployment, not bypassed only in preflight.

| Area | Standard RHEL9 behavior |
|---|---|
| Preflight00, both roles | No CA/cert/key/store-password/admin-DN input checks |
| PostgreSQL06 | `ssl=off`; ordinary host SCRAM rules; both loopbacks/CIDR first; no `hostssl` prerequisite |
| CM database11 | Explicit `sslmode=disable`; no `--ssl`, SSL factory, CA or database truststore dependency |
| CM / agents | HTTP7180; agent `use_tls=0` in the correct General section; no Auto-TLS invocation |
| CDP / ZooKeeper | Standard unencrypted service setup; client/quorum TLS disabled; HTTP web endpoints |
| NiFi / Registry16 | HTTP8080/18080, HTTPS unset, certificate-store paths empty, no login/DN setup |
| Java / SafeLogic | CCJ4, BCJSSE and Cloudera SASL retained; both JDKs configured/validated; BCFKS support retained |
| NiFi sensitive values | PBKDF2/AES-GCM and the intended shared key retained |
| Validation17 | HTTP, actual JDK21/FIPS flags and UI responses; no certificate-store loads or TLS handshake |
| Optional TLS | Moved outside RHEL9 into root `TLS/`, with its own EXPORTS/helpers/tests and explicit workflow |

The OS and operational lessons from both original source repositories remain: required diagnostic/build packages, CodeReady/PGDG signing-key handling, chrony/rngd, firewalld/fapolicyd disabling/masking, SELinux mode, persistent THP/sysctl/limits, native psycopg2 plus real agent-wrapper checks, intact OS Python/packaged agent wrapper, separate upstream JDK17/21 homes, custom PGDATA traversal/ownership/major guards, correct JDBC connector linkage on manager and workers, manager's own agent/supervisord, safe SQL quoting, existing passwords/UUID preservation, version-pinned CM RPMs, exact CSD/parcel build lock, provider distribution to all three CFM directories, CDP-first SASL staging and scoped descriptor/provider backups.

All49 original RHEL8 files remain unchanged. The root README routes users to the standard RHEL9 installation and the independently optional TLS module. The non-FIPS repository remains a read-only source input; its current default NiFi1 profile was not mistaken for a NiFi2 release selection.

Optional certificate/identity tests moved with the optional module; core tests now explicitly exercise operation without that folder. The add-on does not regenerate or rotate an already-deployed NiFi sensitive-property key.
