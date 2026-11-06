# RHEL9 HTTP lab installation with OS / Java FIPS

Start with [INSTALL.md](INSTALL.md). The standard installation uses HTTP for CM, CDP web services, NiFi and Registry; agent encryption is disabled; PostgreSQL uses non-SSL SCRAM.

**No CA, certificates, private keys, certificate DNs or Auto-TLS passwords are required.** SafeLogic CCJ4, Java17/21 FIPS provider setup and NiFi FIPS sensitive-property encryption remain enabled.

Default interfaces: CM7180, NiFi8080, Registry18080, PostgreSQL5432. NiFi/Registry HTTP access is unauthenticated.

Preflight runs without Java installed. Step04 automatically downloads and verifies upstream JDK17/21, installs both homes, selects Java17 for CM and applies the SafeLogic FIPS configuration. Stage only the proprietary SafeLogic bundle and fill in the site settings/credentials in `EXPORTS`; no manual JDK staging is needed for the standard connected installation.

TLS is a separate optional add-on at the repository root under `TLS/`, with its own configuration. Core scripts never source or invoke it.

- [EXPORTS](EXPORTS): site inputs and version pins.
- [SOURCES.md](SOURCES.md): evidence and HTTP/FIPS scope.
- [MERGE_NOTES.md](MERGE_NOTES.md): retained deployment lessons and this rebuild.
- [VALIDATION.md](VALIDATION.md): completed checks and target-host acceptance.
