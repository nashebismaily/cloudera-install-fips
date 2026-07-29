#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

ensure_hosts_csv
require_file "${AUTO_TLS_ISSUED_CA_CHAIN_FILE}"
[[ -n "${KEYTOOL}" && -x "${KEYTOOL}" ]] || fail "keytool not found or not executable: ${KEYTOOL}"
require_cmd "${OPENSSL_BIN}"
prepare_dirs

"${SYSTEM_PYTHON_BIN}" - <<'PY'
import csv
import os
import re
import subprocess
from pathlib import Path

hosts_csv = Path(os.environ["AUTO_TLS_HOSTS_CSV"])
key_dir = Path(os.environ["AUTO_TLS_KEY_DIR"])
cert_dir = Path(os.environ["AUTO_TLS_CERT_DIR"])
fullchain_dir = Path(os.environ["AUTO_TLS_FULLCHAIN_DIR"])
store_dir = Path(os.environ["AUTO_TLS_STORE_DIR"])
openssl_dir = Path(os.environ["AUTO_TLS_OPENSSL_DIR"])
ca_chain = Path(os.environ["AUTO_TLS_ISSUED_CA_CHAIN_FILE"])
openssl_bin = os.environ["OPENSSL_BIN"]
keytool = os.environ["KEYTOOL"]
encrypt_keys = os.environ["AUTO_TLS_ENCRYPT_HOST_KEYS"] == "true"
host_key_password_file = Path(os.environ["AUTO_TLS_HOST_KEY_PASSWORD_FILE"])


def run(cmd, *, quiet=False):
    printable = []
    redact_next = False
    for item in map(str, cmd):
        if redact_next:
            printable.append("[REDACTED]")
            redact_next = False
        else:
            printable.append(item)
            if item in {"-storepass", "-keypass", "-srcstorepass", "-deststorepass", "-passin", "-passout"}:
                redact_next = True
    print("[DEBUG] " + " ".join(printable))
    result = subprocess.run(cmd, universal_newlines=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if not quiet and result.stdout:
        print(result.stdout, end="")
    if result.stderr and (result.returncode or not quiet):
        print(result.stderr, end="")
    if result.returncode:
        raise SystemExit(f"[ERROR] Command failed with return code {result.returncode}")


def command_succeeds(cmd):
    result = subprocess.run(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=False,
    )
    return result.returncode == 0


def assert_key_protection_mode(path, host_id):
    """Require the actual PEM key protection to match AUTO_TLS_ENCRYPT_HOST_KEYS."""
    empty_password_cmd = [
        openssl_bin, "pkey", "-in", str(path),
        "-passin", "pass:", "-check", "-noout",
    ]
    readable_without_password = command_succeeds(empty_password_cmd)

    if encrypt_keys:
        if readable_without_password:
            raise SystemExit(
                f"[ERROR] Private key for {host_id} is unencrypted, but "
                "AUTO_TLS_ENCRYPT_HOST_KEYS=true. Set the flag to false for a "
                "customer-supplied key without a password, or replace the key "
                "with an encrypted key."
            )
        if not host_key_password_file.is_file():
            raise SystemExit(
                f"[ERROR] Host-key password file is missing for encrypted key {host_id}: "
                f"{host_key_password_file}"
            )
        password_cmd = [
            openssl_bin, "pkey", "-in", str(path),
            "-passin", f"file:{host_key_password_file}", "-check", "-noout",
        ]
        if not command_succeeds(password_cmd):
            raise SystemExit(
                f"[ERROR] Private key for {host_id} is encrypted, but the configured "
                "AUTO_TLS_HOST_KEY_PASSWORD cannot read it."
            )
        return

    if not readable_without_password:
        raise SystemExit(
            f"[ERROR] Private key for {host_id} is encrypted or unreadable, but "
            "AUTO_TLS_ENCRYPT_HOST_KEYS=false. Set the flag to true and provide "
            "AUTO_TLS_HOST_KEY_PASSWORD, or supply an unencrypted private key."
        )


chain_text = ca_chain.read_text()
chain_blocks = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", chain_text, flags=re.S)
if not chain_blocks:
    raise SystemExit(f"[ERROR] No certificates found in CA chain: {ca_chain}")
chain_dir = openssl_dir / "truststore-ca-chain"
chain_dir.mkdir(parents=True, exist_ok=True)
for old in chain_dir.glob("*.pem"):
    old.unlink()
chain_files = []
for i, block in enumerate(chain_blocks, 1):
    path = chain_dir / f"ca-{i}.pem"
    path.write_text(block + "\n")
    path.chmod(0o644)
    chain_files.append(path)

created = 0
with hosts_csv.open(newline="") as f:
    reader = csv.DictReader(f)
    if not reader.fieldnames:
        raise SystemExit("[ERROR] hosts.csv has no header row")
    for row in reader:
        host_id = (row.get("host_id") or row.get("hostname") or row.get("host") or "").strip()
        if not host_id or host_id.startswith("#"):
            continue
        key = key_dir / f"{host_id}-key.pem"
        cert = cert_dir / f"{host_id}-cert.pem"
        fullchain = fullchain_dir / f"{host_id}-fullchain.pem"
        keystore = store_dir / f"{host_id}-keystore.p12"
        truststore = store_dir / f"{host_id}-truststore.p12"
        for path, label in ((key, "private key"), (cert, "certificate"), (fullchain, "full chain")):
            if not path.is_file():
                raise SystemExit(f"[ERROR] Missing {label} for {host_id}: {path}")

        assert_key_protection_mode(key, host_id)

        
        if keystore.exists():
            keystore.unlink()
        
        if truststore.exists():
            truststore.unlink()

        pkcs12_cmd = [
            openssl_bin, "pkcs12", "-export",
            "-name", host_id,
            "-inkey", str(key),
            "-in", str(cert),
            "-certfile", str(ca_chain),
            "-out", str(keystore),
            "-passout", f"file:{os.environ['AUTO_TLS_KEYSTORE_PASSWORD_FILE']}",
        ]
        if encrypt_keys:
            pkcs12_cmd += ["-passin", f"file:{os.environ['AUTO_TLS_HOST_KEY_PASSWORD_FILE']}"]
        run(pkcs12_cmd)
        keystore.chmod(0o600)

        for index, ca_file in enumerate(chain_files, 1):
            alias = f"{os.environ['AUTO_TLS_CA_STORE_ALIAS']}-{index}"
            run([
                keytool, "-importcert", "-noprompt",
                "-alias", alias,
                "-file", str(ca_file),
                "-keystore", str(truststore),
                "-storetype", os.environ["AUTO_TLS_STORE_TYPE"],
                "-storepass", os.environ["AUTO_TLS_TRUSTSTORE_PASSWORD"],
            ], quiet=True)
        truststore.chmod(0o600)

        print(f"[OK] Built keystore: {keystore}")
        print(f"[OK] Built truststore: {truststore}")
        created += 1

if created < 1:
    raise SystemExit("[ERROR] No stores were created")
print(f"[OK] Built PKCS12 stores for {created} host(s)")
PY

chmod "${AUTO_TLS_PRIVATE_FILE_MODE}" "${AUTO_TLS_STORE_DIR}"/*.p12
apply_owner_if_available

echo "[OK] PKCS12 keystore and truststore generation completed"
