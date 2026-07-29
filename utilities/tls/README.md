# Cloudera Manager Auto-TLS Utility

This utility is designed for the repository:

```text
/root/cloudera-install-fips
```

The scripts derive the repository root from their own location, so the repository can remain at this exact path.

## Install this update

From the extracted update package, run:

```bash
sudo bash APPLY_UPDATE.sh
```

That replaces `utilities/tls` while preserving the server's active `EXPORTS`,
`hosts.csv`, and `tls.env`. Use `--replace-exports` only when the full replacement
`EXPORTS` in the package has been reviewed.

## What is automated

The workflow now handles:

- Creating `hosts.csv` from `MANAGER_HOST` and `AGENT_HOST` when no inventory exists.
- Creating the dedicated `autotls` Linux account on the manager and agent hosts.
- Generating the dedicated RSA SSH keypair on the manager.
- Installing the public key and passwordless-sudo rule on every host.
- Validating passwordless SSH and sudo before calling Cloudera Manager.
- Generating encrypted or unencrypted PEM host private keys.
- Generating CSRs with configured DNS and IP SANs.
- Packaging only public CSR material for the customer CA team.
- Accepting customer-issued certificates in a separate `issued` directory.
- Signing the same CSRs with an internal test CA for workflow testing.
- Validating key/CSR/certificate matches, SANs, EKUs, chain, dates, and uniqueness.
- Building password-protected PKCS12 keystores and truststores.
- Generating the `generateCmca` payload.
- Running a dry run or submitting the live Auto-TLS API command.
- Polling the Cloudera Manager command until it succeeds or fails.
- Optionally restarting the CM server, all agents, the Cloudera Management
  Service, deploying client configuration, and restarting clusters.

## One unavoidable bootstrap requirement

The manager must already have one administrative way to reach each remote host
before the utility can install the dedicated `autotls` account. The script tries
these methods in order:

1. `AUTO_TLS_BOOTSTRAP_KEY_FILE`
2. The root user's normal SSH identities or loaded ssh-agent
3. `AUTO_TLS_BOOTSTRAP_PASSWORD` through `sshpass`

After that one-time bootstrap, the generated `/home/autotls/.ssh/id_rsa` key is
used by Cloudera Manager Cert Manager. No manual user creation, key generation,
`authorized_keys` editing, or sudoers editing is required.

## Configure the repository

Edit:

```bash
cd /root/cloudera-install-fips
vi EXPORTS
```

At minimum set:

```bash
export MANAGER_HOST='cm01.example.com'
export AUTO_TLS_CM_USER='admin'
export AUTO_TLS_CM_PASSWORD='yourCmPassword'
export AUTO_TLS_KEYSTORE_PASSWORD='AlphanumericPassword123'
export AUTO_TLS_TRUSTSTORE_PASSWORD='AlphanumericPassword456'
```

Passwords used by this Cloudera Auto-TLS flow must be longer than 12 characters
and contain letters and numbers only.

### PEM key without a password

```bash
export AUTO_TLS_ENCRYPT_HOST_KEYS='false'
export AUTO_TLS_HOST_KEY_PASSWORD=''
```

The PKCS12 keystore and truststore are still protected by their independent
passwords.

### PEM key with a password

```bash
export AUTO_TLS_ENCRYPT_HOST_KEYS='true'
export AUTO_TLS_HOST_KEY_PASSWORD='AlphanumericHostKey123'
```

## Create the host inventory

Normally no manual inventory creation is required. When `hosts.csv` is absent,
`run_autotls.sh` creates it from `MANAGER_HOST`, `AGENT_HOST`, and
`AUTO_TLS_HOST_LIST`.

To generate or display it explicitly:

```bash
cd /root/cloudera-install-fips/utilities/tls
sudo -E bash run_autotls.sh inventory
```

For production, review the generated file and add any load balancer, VIP, DNS
alias, or additional SAN entries before submitting CSRs. A custom inventory can
still be created from `hosts.csv.example`.


Example:

```csv
host_id,common_name,dns_sans,ip_sans
cm01.example.com,cm01.example.com,cm01.example.com;cm-vip.example.com,10.0.3.55
nifi01.example.com,nifi01.example.com,nifi01.example.com,10.0.11.4
```

`host_id` must exactly match the hostname known by Cloudera Manager.

## Automatic SSH setup

To set up or repair the dedicated SSH identity by itself:

```bash
cd /root/cloudera-install-fips/utilities/tls
sudo -E bash run_autotls.sh setup-ssh
```

The normal `test`, `customer`, `enable`, and `all` workflows call this step
automatically when `AUTO_TLS_SSH_AUTO_SETUP=true`.

## Customer certificate workflow

Use production-safe settings:

```bash
export AUTO_TLS_CERT_MODE='customer'
export AUTO_TLS_DRY_RUN='true'
export AUTO_TLS_ALLOW_TEST_CA_ENABLE='false'
```

Generate and package the requests:

```bash
cd /root/cloudera-install-fips/utilities/tls
sudo -E bash run_autotls.sh prepare-csrs
```

Send only:

```text
/opt/cloudera/AutoTLS/artifacts/requests/customer-csr-package.tar.gz
```

The customer returns files using the names in the manifest:

```text
/opt/cloudera/AutoTLS/artifacts/issued/<host_id>-cert.pem
/opt/cloudera/AutoTLS/artifacts/issued/ca-chain.pem
```

Then run:

```bash
sudo -E bash run_autotls.sh customer
```

With `AUTO_TLS_DRY_RUN=true`, everything is validated and the payload is built,
but Cloudera Manager is not changed.

## Internal test-CA workflow

```bash
export AUTO_TLS_CERT_MODE='test'
export AUTO_TLS_ALLOW_TEST_CA_ENABLE='true'
export AUTO_TLS_DRY_RUN='true'
```

Run the complete non-live workflow:

```bash
cd /root/cloudera-install-fips/utilities/tls
sudo -E bash run_autotls.sh test
```

The test CA signs the exact same CSRs that would be sent to a customer.

## Live Auto-TLS submission

After a complete dry run succeeds:

```bash
export AUTO_TLS_DRY_RUN='false'
export AUTO_TLS_CONFIRM_LIVE='ENABLE-AUTOTLS'
```

Run the workflow again:

```bash
sudo -E bash run_autotls.sh enable
```

The script submits `generateCmca` and polls the returned Cloudera Manager
command. It does not report success merely because the HTTP request was
accepted.

## Post-enable restart automation

After `generateCmca` completes successfully:

```bash
export AUTO_TLS_CONFIRM_POST_RESTART='RESTART-AUTOTLS'
sudo -E bash run_autotls.sh post-restart
```

This restarts the CM server, waits for HTTPS, restarts all CM agents, restarts
the Cloudera Management Service, deploys client configuration where supported,
and restarts each cluster.

To run it automatically after a successful live submission:

```bash
export AUTO_TLS_AUTO_POST_RESTART='true'
export AUTO_TLS_CONFIRM_POST_RESTART='RESTART-AUTOTLS'
```

## Reset only Auto-TLS staging

This does not create backup clutter and removes only the configured
`AUTO_TLS_LOCATION`:

```bash
sudo -E bash run_autotls.sh reset --yes
```

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
06_build_pkcs12_stores.sh
07_validate_artifacts.sh
08_validate_autotls_prereqs.sh
09_enable_autotls.sh
10_post_enable_restart.sh
run_autotls.sh
```

## Security behavior

- Private keys and passwords are never included in the customer CSR package.
- Existing keys and certificates are not silently overwritten by default.
- Unencrypted PEM input keys do not create pre-deployment host-key password files.
- Keystore and truststore passwords remain mandatory even when PEM keys are unencrypted.
- Live test-CA enablement is blocked unless explicitly allowed.
- Live API submission and post-enable restart each have explicit confirmation guards.
