# Optional standalone TLS add-on

This folder is used **only when a user chooses to add TLS after the HTTP lab installation**. It has its own `EXPORTS` and optional `tls.env`. It never imports `RHEL9/EXPORTS` or calls the core installer. Copying this folder to a prepared host is sufficient; the already-installed upstream JDKs and SafeLogic providers must remain available on that host.

The standard installation does not need this folder. All existing RHEL8 utilities remain with the historical RHEL8 profile.

## 1. Configure the independent add-on

```bash
cd /root/cloudera-install-fips/TLS
vi EXPORTS
cp tls.env.example tls.env
chmod 600 EXPORTS tls.env
```

Set the real manager/hostnames, CM API credentials, all managed hosts in `hosts.csv`, approved JDK/provider paths and independent store/key passwords. Passwords for this flow are alphanumeric and at least14 characters. Use `hosts.csv.example` or the inventory helper; include the manager and every worker, with the exact CM hostname, CN and required SANs.

Do not copy the core HTTP NiFi safety valve forward into a secured deployment: it explicitly clears certificate settings and disables secure transport. Replace those snippets during this workflow. Keep the **existing NiFi sensitive-property key and algorithm unchanged**; this add-on does not regenerate them.

## 2. Customer-CA workflow

On a host with OS FIPS and the already-configured JDK17/CCJ4 providers:

```bash
sudo -E bash run_autotls.sh inventory
sudo -E bash run_autotls.sh prepare-csrs
```

Review the inventory and send **only** the generated `customer-csr-package.tar.gz` to the CA. It contains CSRs, SAN/filename instructions and checksums, not private keys/passwords. Default returned files are under `/opt/cloudera/AutoTLS/artifacts/issued/`: one `<hostname>-cert.pem` leaf per host and `ca-chain.pem`, ordered issuer/intermediates first and root last. Keys remain under `artifacts/private/`.

Certificates require distinct host identities, requested SANs, serverAuth **and clientAuth**, suitable key strength/signature and valid dates. Customer keys may be encrypted or unencrypted, but `AUTO_TLS_ENCRYPT_HOST_KEYS` and its password must match the actual material. Encrypted host keys use the required per-host `hosts-key-store/<hostname>/cm-auto-host_key.pw` files.

Keep `AUTO_TLS_DRY_RUN=true` and validate returned files:

```bash
sudo -E bash run_autotls.sh customer
```

This checks keys/CSRs/certificates/chains/SANs/EKUs/permissions, builds BCFKS stores directly through CCJ, validates their contents and prepares the payload without SSH account changes or CM API calls. Production store building does not create a private-key PKCS12 intermediate.

## 3. Explicit live activation

Plan an outage and stop affected NiFi/Registry/Runtime roles in CM before changing their transports. Preserve flow/Registry data and authorization state. Configure actual API credentials and the existing administrative SSH route for one-time dedicated Auto-TLS SSH setup.

Edit this folder's configuration:

```bash
export AUTO_TLS_DRY_RUN='false'
export AUTO_TLS_CONFIRM_LIVE='ENABLE-AUTOTLS'
export AUTO_TLS_CONFIRM_POST_RESTART='RESTART-AUTOTLS'
```

Then run:

```bash
sudo -E bash run_autotls.sh enable
sudo -E bash run_autotls.sh post-restart
```

The workflow validates SSH/sudo and service-user access, submits `generateCmca` and polls its terminal success. Post-restart prepares the merged public/cluster CA truststore, adds the optional CM Java trust/GCM settings and verifies trusted HTTPS before restarting agents. This profile leaves cluster and Management Service automatic restarts off until the application configuration transition is complete.

If the cluster CA is not at `CM_CLUSTER_CA_FILE`, set that field to the actual trusted public chain. Do not infer store format from a `.jks` extension; CM may store BCFKS there.

## 4. Configure CFM HTTPS and restart stopped applications

Set actual full **unmapped administrator DNs** and `NIFI_NODE_HOSTS` in this folder's `EXPORTS`. Certificate-derived node templates avoid invented OU suffixes. On every role host prepare its optional runtime truststore/systemd environment:

```bash
sudo -E bash 12_generate_cfm_tls_config.sh trust
```

On the manager, with the returned public certificates/inventory available:

```bash
sudo -E bash 12_generate_cfm_tls_config.sh render
```

Replace the old HTTP snippets with generated HTTPS snippets under `/var/lib/cloudera-bootstrap/tls-config`. Configure the actual administrator identities, enable service TLS, use CM's Auto-TLS BCFKS stores and the real passwords. Keep Java21 for both CFM roles. The generated bootstrap options add GCM, BCFKS trust and approved provider flags. They do not change the existing sensitive-property key.

Apply all settings to every applicable role group. The optional systemd drop-ins must be loaded before starting Java roles; with roles stopped, reload systemd and restart the agent/supervisord in the supported sequence. Start the Management Service and selected CDP/CFM services through CM only after their TLS configuration is complete.

On each relevant CFM role host:

```bash
sudo -E bash 13_validate_cfm_tls_runtime.sh nifi
# Or registry / nifi,registry
```

This checks effective secure settings, running JDK21, real BCFKS stores and a real BCJSSE mutual TLS handshake with hostname verification. The core HTTP validator is for the original HTTP profile, not the newly secured services.

## 5. PostgreSQL TLS is an additional explicit action

Auto-TLS does not enable database TLS. This add-on's `DB_SSLMODE` defaults to `disable` so an application-only TLS transition leaves existing database connectivity alone.

To separately enable PostgreSQL TLS, use a server certificate matching `DB_HOST`, its dedicated key and issuing CA chain:

```bash
sudo -E bash prepare_postgres_tls.sh request
# Have the CA sign the CSR and place the returned files at the configured paths.
sudo -E bash prepare_postgres_tls.sh validate
```

Set `DB_SSLMODE=verify-full` **in this folder's configuration**, stage/distribute the public CA to database clients, then:

```bash
sudo -E bash 21_enable_postgres_tls.sh
```

Before restarting database clients, update CM's database JDBC URL/SSL settings with the vendor database utility, Reports Manager's database SSL settings, and Registry's JDBC URL. Use full hostname verification and the actual CA trust. For CM, the URL may use `sslfactory=org.postgresql.ssl.DefaultJavaSSLFactory` and the prepared BCFKS truststore; Registry can use the explicit `sslrootcert` PEM parameter. Refresh the optional truststore with the DB CA after selecting verify-full. Do not switch off working database access before provisioning those client changes during the outage.

The basic HTTP installer is never used to perform this later database conversion.

## Tests and recovery

```bash
bash tools/run_static_validation.sh
bash tests/run_all_tests.sh
```

Portable tests deliberately use an offline non-FIPS store profile, cannot submit live requests and do not certify the actual CCJ/RHEL image. They cover CSR privacy, full dry runs, bad certificates/SANs/passwords, chain order, encrypted/unencrypted keys, inventory and sandboxed SSH reruns. Existing keys/CSRs are reused; do not overwrite issued key material casually. A test-CA workflow remains available for isolated labs via `run_autotls.sh test` and its explicit test-CA guards.

After securing an installation, use this folder's secure configuration/validation workflow. Re-running the core HTTP installation against it is not a transport migration procedure.
