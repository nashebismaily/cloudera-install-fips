# RHEL9 / FIPS 140-3 Auto-TLS utility

Run this utility on the prepared CM server, after the manager/agents are registered and the CDP/CFM parcel preparation in [the installation runbook](../../INSTALL.md) is complete. Production key generation requires the RHEL9 FIPS profile and OS FIPS activation.

The primary configuration is `RHEL9/EXPORTS`. An optional `utilities/tls/tls.env` overrides TLS-specific values. Copy `tls.env.example` only if you want this separate local file. Edit assignments in the files: terminal exports can be replaced when the primary configuration is sourced.

## 1. Configure inventory and credentials

From the manager:

```bash
cd /root/cloudera-install-fips/RHEL9/utilities/tls
cp tls.env.example tls.env
vi tls.env
chmod 600 tls.env
sudo -E bash run_autotls.sh inventory
```

The inventory is generated from `MANAGER_HOST`, `AGENT_HOST`, and optional `AUTO_TLS_HOST_LIST`. It is preserved once it exists. For clusters with more workers, list every managed host in `AUTO_TLS_HOST_LIST` before initial generation, or edit the generated CSV. Review actual CM hostnames and all VIPs, aliases, and SANs before generating CSRs.

```csv
host_id,common_name,dns_sans,ip_sans
cm01.example.com,cm01.example.com,cm01.example.com;cm-vip.example.com,10.0.3.55
nifi01.example.com,nifi01.example.com,nifi01.example.com,10.0.11.4
```

`host_id` must match CM's host name. SAN lists inside a CSV field use semicolons. Wildcards and duplicate hosts are rejected.

Configure the actual CM account credentials. Rotate the CM bootstrap password in CM first, then update the configuration. Host-key, store, CA-key, and API passwords are independent values. Store/key passwords must contain only letters/numbers and be at least 14 characters.

Defaults:

```bash
export AUTO_TLS_CERT_MODE='customer'
export AUTO_TLS_DRY_RUN='true'
export AUTO_TLS_ALLOW_TEST_CA_ENABLE='false'
export AUTO_TLS_STORE_TYPE='BCFKS'
export AUTO_TLS_ENCRYPT_HOST_KEYS='true'
```

Do not override BCFKS or `AUTO_TLS_REQUIRE_FIPS_STORES` for a deployment. An explicitly non-FIPS, offline-only profile exists solely for portable repository tests and cannot submit a live API request.

## 2. Generate keys/CSRs and the public handoff package

```bash
sudo -E bash run_autotls.sh prepare-csrs
```

The default paths are derived from `AUTO_TLS_LOCATION=/opt/cloudera/AutoTLS`:

| Material | Location |
|---|---|
| Private PEM host keys | `artifacts/private/<host_id>-key.pem` |
| CSRs | `artifacts/requests/<host_id>-csr.pem` |
| Public handoff package | `artifacts/requests/customer-csr-package.tar.gz` |
| Returned leaf certificates | `artifacts/issued/<host_id>-cert.pem` |
| Returned CA chain | `artifacts/issued/ca-chain.pem` |
| Full chains | `artifacts/fullchains/<host_id>-fullchain.pem` |
| BCFKS stores | `artifacts/stores/<host_id>-keystore.bcfks` and `-truststore.bcfks` |
| Private password files | `artifacts/passwords/` |
| Payload, reports, API responses | `artifacts/payload/` |

Send **only** `customer-csr-package.tar.gz` to the CA team. It contains CSRs, a filename/SAN manifest, signing instructions, and SHA256 checksums. It excludes private keys and passwords. The package is revalidated before submission.

The customer should return one unique leaf certificate per host and an ordered CA chain: issuing intermediate first, any higher intermediates next, self-signed root last. Leaves need all requested DNS/IP SANs, `CA:FALSE`, and both server/client TLS EKUs. Place files at the exact names listed in the manifest.

## 3. Customer certificates: complete a local dry run

With `AUTO_TLS_DRY_RUN=true`:

```bash
sudo -E bash run_autotls.sh customer
```

If returned files are missing, the command stops with the handoff/return instructions. It does not silently switch to a test CA.

The dry run validates key/CSR/certificate identity, certificate dates/strength, SANs, EKUs, CA chain order/linkage, uniqueness, private file permissions, package checksums, and final store contents. It builds a reviewable payload and local password files. It does **not** distribute SSH accounts/keys or call CM APIs. Missing SSH payload credentials are deferred until the live stage.

BCFKS stores are created directly through the configured Java/CCJ provider. Decrypted PKCS8 key bytes are passed through process memory; no temporary PKCS12 store or unencrypted private-key file is created. The production path needs the approved provider libraries staged by installation step 04.

Use `run_autotls.sh validate` to rerun local validation/building. Full DNS/CM/SSH/service-user prerequisite checks occur when switching to the live configuration.

## 4. Prepare the one-time SSH bootstrap

Before live enablement, the manager needs one administrative route to each remote host:

1. The configured `AUTO_TLS_BOOTSTRAP_KEY_FILE`, or
2. Available normal SSH identities/ssh-agent, or
3. An explicitly configured `AUTO_TLS_BOOTSTRAP_PASSWORD` with `sshpass` installed.

The bootstrap user defaults to root. A non-root bootstrap user must have noninteractive sudo. The script does not attempt an interactive password prompt.

During live setup, the utility creates/reuses the dedicated `AUTO_TLS_SSH_USER` (default `autotls`), its RSA SSH identity, authorized keys, and a validated passwordless-sudo rule. The generated identity is used by CM Cert Manager. Existing authorized keys are preserved, and sudoers updates are idempotent.

To perform SSH setup separately, first make the live settings in the next step, then run:

```bash
sudo -E bash run_autotls.sh setup-ssh
```

With dry run still enabled, this command deliberately defers SSH changes.

## 5. Submit the live Auto-TLS command

After reviewing the successful dry-run artifacts and arranging a maintenance window, edit `tls.env` (or the primary `EXPORTS`):

```bash
export AUTO_TLS_DRY_RUN='false'
export AUTO_TLS_PREREQ_MODE='full'
export AUTO_TLS_CONFIRM_LIVE='ENABLE-AUTOTLS'
```

Then:

```bash
sudo -E bash run_autotls.sh enable
```

This prepares/validates SSH, validates all artifacts, and submits `generateCmca`. The utility polls the returned command ID and checks terminal success. An HTTP acceptance response alone is not considered completion; a missing command ID or failed command blocks automatic continuation.

The custom-CA payload includes each host's certificate/key filenames, CM certificate/key, CA chain, store-password files, SSH credentials, and `configureAllServices`. The private JSON payload is mode `0600`; console summaries redact SSH credentials.

For encrypted PEM keys, the utility creates the Cert Manager per-host file:

```text
/opt/cloudera/AutoTLS/hosts-key-store/<host_id>/cm-auto-host_key.pw
```

If the CA supplied unencrypted keys, set `AUTO_TLS_ENCRYPT_HOST_KEYS=false` and an empty host-key password in the configuration before starting the workflow. The actual key protection mode must match; unencrypted mode removes stale per-host password files. BCFKS store passwords remain mandatory.

## 6. Restart after successful enablement

Edit the configuration:

```bash
export AUTO_TLS_CONFIRM_POST_RESTART='RESTART-AUTOTLS'
```

Run:

```bash
sudo -E bash run_autotls.sh post-restart
```

This first merges approved upstream public roots, database CA, and the issued cluster CA into CM's BCFKS runtime truststore. It then restarts CM Server, waits for a successful trusted HTTPS response, restarts local/remote CM agents, restarts the CM Management Service when configured, deploys client configuration, and restarts each existing cluster according to the configured switches. The fresh-install profile disables the Management Service restart until that service exists. It polls asynchronous service/cluster commands.

Set `AUTO_TLS_CA_FILE` to the appropriate trusted PEM bundle if needed; post-restart defaults to the issued CA chain. TLS verification stays enabled unless the explicit lab override is selected. For an already HTTPS-enabled CM API, configure its scheme, port, and CA accordingly.

Automatic post-restart is available with `AUTO_TLS_AUTO_POST_RESTART=true` plus the separate restart confirmation. Use the normal manual post-restart command when reviewing the live command first.

CM's default HTTPS UI is `https://<manager>:7183`. After successful TLS enablement, update the general installer ready-state settings `CM_RUNTIME_PROTOCOL`, `CM_RUNTIME_PORT`, and `CM_RUNTIME_CA_FILE` in the primary `EXPORTS` as described in the installation runbook.

## 7. Configure and validate CFM roles

Continue with installation steps 16 and 17. Run step16 in `trust` mode on every role host, then `render` mode on the manager to derive actual node DNs and generate all NiFi/Registry snippets. Set each service's Java 21 home, apply BCFKS/GCM/SASL/sensitive-property settings in CM, and validate the running services. Auto-TLS does not substitute for these service-specific steps.

## Test CA workflow

On an isolated FIPS lab host only, configure `AUTO_TLS_CERT_MODE=test`, a long test-CA key password, and `AUTO_TLS_DRY_RUN=true`, then run:

```bash
sudo -E bash run_autotls.sh test
```

The test CA signs the same CSR material used in the customer workflow. Live use is rejected unless `AUTO_TLS_ALLOW_TEST_CA_ENABLE=true` is deliberately configured in addition to all normal live guards. Never overwrite customer-returned files with a test chain.

## Recovery and preservation

Existing keys/CSRs/CA files are validated and reused by default. The explicit overwrite switches are for an intentional replacement; regenerated keys invalidate previously issued certificates.

For a deliberate rebuild of this utility's staging files only:

```bash
sudo -E bash run_autotls.sh reset --yes
```

Reset requires the utility's staging marker and rejects protected parent directories. It does not revoke certificates or disable an already enabled CM Auto-TLS deployment. Do not reset the only copy of required keys or active certificate artifacts.

For `bad decrypt`, verify the configured mode/password against the actual PEM key. For missing host-key password errors, verify the per-host `cm-auto-host_key.pw` path. For class/module/provider failures, rerun installation step 04 and the service-user provider checks. For HTTPS failures, check CA trust, SANs, time, GCM bootstrap settings, and actual BCFKS store contents.

## Individual scripts

```text
00_prepare_inventory.sh
00_setup_autotls_ssh.sh
00_prepare_dirs.sh
01_generate_keys_csrs.sh
02_package_customer_csrs.sh
03_create_test_ca.sh
04_sign_csrs_with_test_ca.sh
05_validate_issued_certificates.sh
06_build_stores.sh
07_validate_artifacts.sh
08_validate_autotls_prereqs.sh
09_enable_autotls.sh
10_post_enable_restart.sh
```

Normal deployments should use `run_autotls.sh` so the required ordering and live guards are applied consistently.
