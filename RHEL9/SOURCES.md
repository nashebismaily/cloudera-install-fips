# Source evidence — reviewed 2026-11-06

## Source repositories and supplied bundle

| Input | Revision / evidence |
|---|---|
| [RHEL8 FIPS deployment kit](https://github.com/nashebismaily/cloudera-install-fips) | `8b1721a1f8e8811ce0e00a15575b6b7bcafd1ac9` |
| [Non-FIPS deployment kit](https://github.com/nashebismaily/cloudera-install-nonfips) | `26973926c3241a3718a4d52ed31f98c99956c9a4` |
| SafeLogic bundle | User-supplied screenshot of `Cloudera-Base-on-premise-7.3.2-SP1-Safelogic-FIPS-Modules-07282026.tar.gz`: seven JARs and seven SHA256 sidecars |
| RHEL9.8 compatibility | Customer reports internal Cloudera confirmation. No public 9.8 FIPS entry was established by this review. |

The current non-FIPS HEAD is profile-driven but defaults to CFM 2.1.7.3000 / NiFi 1.28.1. Its optional Java21/Python3.11 settings and NiFi2 deployment lessons were reviewed; its baseline versions and Python3.9 wrapper symlink were not treated as the NiFi2/FIPS target.

## Selected matrix and primary documentation

| Decision | Primary source |
|---|---|
| CM **7.13.2.10000** + Base **7.3.2 SP1** for FIPS140-3 | [Supported Cloudera deployments](https://docs.cloudera.com/cdp-private-cloud-base/7.3.2/cdp-private-cloud-base-installation/topics/cdpdc-support-cdp-versions.html) |
| CFM **4.12.0.10001** with that FIPS stack; public OS entry **RHEL9.6** | [CFM FIPS deployment procedure](https://docs.cloudera.com/cfm/4.12.0/cfm-security/topics/cfm-deploy-on-fips-clusters.html) |
| .10001 fixes SP1 .10000 truncated library/NAR filenames | [CFM fixed issues](https://docs.cloudera.com/cfm/4.12.0/release-notes/topics/cfm-fixed-issues.html) and [CFM release changes](https://docs.cloudera.com/cfm/latest/release-notes/topics/cfm-whats-new.html) |
| NiFi / Registry **2.6.0** in CFM4.12 SP1 | [Component versions](https://docs.cloudera.com/cfm/4.13.0/release-notes/topics/cfm-component-support.html), including its historical 4.12.0.10001 entry |
| SP1 Runtime is **7.3.2.10000**; CM SP1 is minimum for it | [CM version information](https://docs.cloudera.com/cdp-private-cloud-upgrade/latest/release-guide/topics/cdpdc-cm-version-information.html) and [CM/Runtime compatibility](https://docs.cloudera.com/cdp-private-cloud-upgrade/latest/upgrade/topics/cm-cdh-compatibility.html) |
| Runtime requires Java17/Python3.11; PG14 deprecated in SP1 | [Runtime platform changes](https://docs.cloudera.com/cdp-private-cloud-base/7.3.2/private-release-notes/topics/rt-deprecated-platform-os.html) |
| CM generation supports PostgreSQL16 | [CM7.13.2 release notes](https://docs.cloudera.com/cdp-private-cloud-base/7.3.2/manager-release-notes/cm-release-notes.pdf), database-support section |
| Standard-location Python3.11 supported in CM SP1; preserve packaged wrapper | [Python guidelines](https://docs.cloudera.com/cdp-private-cloud-upgrade/latest/upgrade-cdp/topics/upgrade-python-cdp.html) and [SP1 Python installation constraints](https://docs.cloudera.com/cloudera-manager/7.13.2/cloudera-manager-installation/topics/cdpdc-cm-install-python-312-os-standard-location.html) |

The explicit FIPS SP1 combination was selected for the supplied SP1 crypto bundle. The [general CFM download page](https://docs.cloudera.com/cfm/latest/release-notes/topics/cfm-download-locations.html) now advertises .20000, and general CM/Runtime pages also advertise newer service packs. A generic platform compatibility entry does not, by itself, establish that a different release/bundle combination is the documented FIPS configuration. No automatic product-release upgrade is performed.

## Installation details used

| Detail | Primary source |
|---|---|
| RHEL9 entropy ceiling; OS FIPS first; upstream JDK instead of RHEL-modified Java; CCJ4/BCTLS/BCUTIL; release-specific SASL archive/destinations | [Preparing hosts for FIPS](https://docs.cloudera.com/cdp-private-cloud-base/7.3.2/cdp-private-cloud-base-installation/topics/cdpdc-enable-hosts-jdk17.html) |
| CM FIPS flags, FIPS SASL, BCUTIL classpath and module-name discovery | [Installing CM Server for FIPS](https://docs.cloudera.com/cdp-private-cloud-base/7.3.2/cdp-private-cloud-base-installation/topics/cdpdc-install-cm-server-jdk17.html) |
| Configure Java17 **and Java21**, copy core JARs to all three CFM lib directories, GCM, bootstrap XML, BCFKS, sensitive algorithm, DIGEST-SHA | [CFM FIPS deployment procedure](https://docs.cloudera.com/cfm/latest/cfm-security/topics/cfm-deploy-on-fips-clusters.html) |
| Preserve approved public CA roots by explicitly using BCFKS trust | [Additional FIPS components / truststore behavior](https://docs.cloudera.com/cdp-private-cloud-base/7.3.2/cdp-private-cloud-base-installation/topics/cdpdc-fips-install-additional-components.html) |
| CM schema utility TLS/JDBC URL options | [CM installation guide](https://docs.cloudera.com/cdp-private-cloud-base/7.3.2/installation/cm-installation.pdf), syntax for `scm_prepare_database.sh` |
| PostgreSQL TLS server/client configuration | [PostgreSQL16 server TLS](https://www.postgresql.org/docs/16/ssl-tcp.html), [libpq TLS](https://www.postgresql.org/docs/16/libpq-ssl.html), [JDBC TLS](https://jdbc.postgresql.org/documentation/ssl/) |
| NiFi identity mapping also applies to full initial-admin/node DNs | [CFM security guide](https://docs.cloudera.com/cfm/4.12.0/cfm-security/cfm-security.pdf), identity mapping section |
| RHEL OS FIPS activation and provisioning requirements | [Red Hat security hardening](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/switching-rhel-to-fips-mode_security-hardening), linked by Cloudera's host-preparation procedure |

Public docs contain spelling/version inconsistencies: the host guide mentions both `ccj-4.0.0.jar` and `ccj-4.0.0-fips.jar`, and one CM paragraph shortens the SP1 numeric suffix. This kit uses the actual screenshot filename and the explicit supported-version table. The doubled `com.cloudera.cloudera.cmf.fipsMode.jdk11plus` prefix is intentional because it appears in the documented CM options.

## Values that require entitled inputs

- Actual vendor-supported JDK17/JDK21 archives, patch levels and trusted digests.
- Actual SafeLogic binary files, original checksum contents, module metadata and module validation policy.
- Exact internal SASL build and exact CFM/CDP parcel builds. The preflight resolves these from the pinned entitled repositories and records them; synthetic build numbers occur only in offline test fixtures.
- Enterprise certificates, actual DNs/SANs, archive/API credentials, service topology and required external integrations.

The .10001 EL9 archive path follows Cloudera's product/version/platform repository structure and is checked with entitled access before host package/OS changes. This environment has no customer download credentials, so this review does not assert a successful download of that protected release. Missing entitlement, ambiguous builds or an unavailable artifact stops preparation rather than choosing another release.

The RHEL9.8 internal confirmation and a screenshot of filenames are not substitutes for live acceptance of the actual RHEL image and cryptographic binaries. See [VALIDATION.md](VALIDATION.md) for completed tests and remaining target-host checks.
