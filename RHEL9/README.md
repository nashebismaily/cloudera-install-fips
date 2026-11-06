# RHEL 9.8 FIPS installation

Start with [INSTALL.md](INSTALL.md). It covers the complete manager/worker, OS FIPS, PostgreSQL, Auto-TLS, CDP/ZooKeeper, NiFi 2 and Registry workflow.

- [EXPORTS](EXPORTS): deployment configuration and pinned versions.
- [SOURCES.md](SOURCES.md): vendor references and the internally confirmed RHEL9.8 target.
- [MERGE_NOTES.md](MERGE_NOTES.md): lessons merged from both source repositories.
- [VALIDATION.md](VALIDATION.md): completed offline checks and required live acceptance.

Selected FIPS SP1 combination: CM **7.13.2.10000**, CDP **7.3.2.10000**, CFM **4.12.0.10001** / NiFi **2.6.0**, Java **17 + 21**, CCJ **4.0.0**. Public FIPS instructions list RHEL9.6; the installer targets RHEL9.8 on the customer's internal confirmation.
