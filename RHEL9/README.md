# RHEL9 HTTP lab installation with OS / Java FIPS

Start with [INSTALL.md](INSTALL.md). The standard installation uses HTTP for CM, CDP web services, NiFi and Registry; agent encryption is disabled; PostgreSQL uses non-SSL SCRAM.

**No CA, certificates, private keys, certificate DNs or Auto-TLS passwords are required.** SafeLogic CCJ4, Java17/21 FIPS provider setup and NiFi FIPS sensitive-property encryption remain enabled.

Default interfaces: CM7180, NiFi8080, Registry18080, PostgreSQL5432. NiFi/Registry HTTP access is unauthenticated.

TLS is a separate optional add-on at the repository root under `TLS/`, with its own configuration. Core scripts never source or invoke it.

- [EXPORTS](EXPORTS): site inputs and version pins.
- [SOURCES.md](SOURCES.md): evidence and HTTP/FIPS scope.
- [MERGE_NOTES.md](MERGE_NOTES.md): retained deployment lessons and this rebuild.
- [VALIDATION.md](VALIDATION.md): completed checks and target-host acceptance.
