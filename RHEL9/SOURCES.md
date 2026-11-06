# Sources and profile scope — reviewed 2026-11-06

## Inputs and selected releases

The rebuild starts from the user's current public repository commit **2707e88** (`Organize RHEL8 and add RHEL9 FIPS installation`), which contains the earlier merged kit. Original deployment inputs remain:

| Input | Revision / evidence |
|---|---|
| [FIPS source](https://github.com/nashebismaily/cloudera-install-fips) | Original RHEL8 implementation at `8b1721a1f8e8811ce0e00a15575b6b7bcafd1ac9` |
| [Non-FIPS source](https://github.com/nashebismaily/cloudera-install-nonfips) | `26973926c3241a3718a4d52ed31f98c99956c9a4` |
| SafeLogic inputs | Supplied screenshot of the SP1 07282026 archive: seven JARs and original SHA256 sidecars |
| RHEL9.8 target | Customer reports internal compatibility confirmation; no public9.8 FIPS entry was established |

Product pins remain CM7.13.2.10000, CDP7.3.2.10000 and CFM4.12.0.10001 / NiFi2.6.0, with upstream Java17/21, Python3.11 and PostgreSQL16. This change removes deployment TLS prerequisites; it does not select another product release or older crypto libraries.

## HTTP support and the user's required scope

| Evidence | Primary source |
|---|---|
| CFM4.12 documents NiFi HTTP8080 and Registry HTTP18080 | [CFM default ports](https://docs.cloudera.com/cfm/4.12.0/cfm-security/topics/cfm-supported-ports.html) |
| User authentication in NiFi/Registry requires TLS; HTTP lab has no login/administrator-DN setup | [CFM authentication](https://docs.cloudera.com/cfm/4.12.0/cfm-security/topics/cfm-security-authentication.html), [NiFi administrator guide](https://nifi.apache.org/nifi-docs/administration-guide.html) |
| CM's admin/agent TLS settings are independently selectable | [CM server properties](https://docs.cloudera.com/cloudera-manager/7.13.1/configuration-properties/topics/cm_props_cmserver.html), `web_tls` / `agent_tls` |
| Advanced encryption flags and Auto-TLS explicitly enable additional transport encryption | [CM protocol configuration](https://docs.cloudera.com/cloudera-manager/7.13.2/cloudera-manager-installation/topics/cm-tls-protocol-config.html) |
| JDBC/libpq allow explicitly disabled SSL transport; SCRAM is independent of TLS | [pgJDBC SSL parameters](https://jdbc.postgresql.org/documentation/ssl/), [PostgreSQL16 client SSL modes](https://www.postgresql.org/docs/16/libpq-ssl.html) |

The core profile is deliberately **HTTP/non-SSL throughout the lab** while retaining OS FIPS, CCJ approved-only providers and FIPS sensitive-property encryption. It does not claim that plaintext transport is encrypted or that this lab is the complete vendor FIPS-secured production procedure. The optional root `TLS/` module is independent and invoked only by the user's later choice.

## Version / FIPS runtime evidence retained

| Decision | Primary source |
|---|---|
| CM SP1 + Base SP1 FIPS140-3 baseline | [Supported Cloudera deployments](https://docs.cloudera.com/cdp-private-cloud-base/7.3.2/cdp-private-cloud-base-installation/topics/cdpdc-support-cdp-versions.html) |
| CFM4.12.0.10001, JDK17/21 split, core providers, SASL, PBKDF2/AES-GCM | [CFM FIPS procedure](https://docs.cloudera.com/cfm/4.12.0/cfm-security/topics/cfm-deploy-on-fips-clusters.html) |
| .10001 corrects .10000 truncated library/NAR names | [CFM fixed issues](https://docs.cloudera.com/cfm/4.12.0/release-notes/topics/cfm-fixed-issues.html) |
| Runtime SP1 numeric version; minimum CM | [CM version information](https://docs.cloudera.com/cdp-private-cloud-upgrade/latest/release-guide/topics/cdpdc-cm-version-information.html) |
| Runtime Python3.11/Java17; PG14 deprecated in SP1 | [Platform changes](https://docs.cloudera.com/cdp-private-cloud-base/7.3.2/private-release-notes/topics/rt-deprecated-platform-os.html) |
| CM generation supports PG16 | [CM release notes](https://docs.cloudera.com/cdp-private-cloud-base/7.3.2/manager-release-notes/cm-release-notes.pdf) |
| Standard-location Python3.11 and intact agent wrapper | [Python guidelines](https://docs.cloudera.com/cdp-private-cloud-upgrade/latest/upgrade-cdp/topics/upgrade-python-cdp.html) |
| OS FIPS first, upstream JDKs, CCJ4/BCTLS/BCUTIL and release-specific SASL locations | [Host preparation](https://docs.cloudera.com/cdp-private-cloud-base/7.3.2/cdp-private-cloud-base-installation/topics/cdpdc-enable-hosts-jdk17.html) |
| Automated upstream JDK resolution/download and vendor SHA256 verification; no Red Hat-modified runtime RPMs | [Adoptium API installation guide](https://adoptium.net/installation/ci-scripts), [Adoptium API](https://api.adoptium.net/q/swagger-ui/) |
| CM FIPS/SASL flags, BCUTIL and actual module names | [CM FIPS installation](https://docs.cloudera.com/cdp-private-cloud-base/7.3.2/cdp-private-cloud-base-installation/topics/cdpdc-install-cm-server-jdk17.html) |
| FIPS Java needs BCFKS public-root preservation for outbound archive access | [Default trust behavior](https://docs.cloudera.com/cdp-private-cloud-base/7.3.2/cdp-private-cloud-base-installation/topics/cdpdc-fips-install-additional-components.html) |

The original sidecars and actual proprietary modules must be supplied. The entitled artifact preparer resolves exact builds instead of inventing suffixes and records hashes/provenance. An optional missing SASL SHA256 sidecar is distinguished from an independently supplied vendor digest; authenticated HTTPS provenance is recorded accurately.

The screenshot does not supply binary JAR contents or digest values. Real RHEL9.8/CCJ/JDK/CM/CFM acceptance remains a target-host action; [VALIDATION.md](VALIDATION.md) distinguishes that from local tests.
