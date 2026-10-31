#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

ensure_hosts_csv
require_file "${AUTO_TLS_ISSUED_CA_CHAIN_FILE}"
require_file "${AUTO_TLS_CSR_PACKAGE_FILE}"
[[ -n "${KEYTOOL}" && -x "${KEYTOOL}" ]] || fail "keytool not found or not executable: ${KEYTOOL}"
require_cmd "${OPENSSL_BIN}"
prepare_dirs

"${SYSTEM_PYTHON_BIN}" - <<'PY' | tee "${AUTO_TLS_VALIDATION_REPORT_FILE}"
import csv
import hashlib
import io
import os
import re
import stat
import subprocess
import tarfile
from pathlib import Path, PurePosixPath

hosts_csv = Path(os.environ["AUTO_TLS_HOSTS_CSV"])
key_dir = Path(os.environ["AUTO_TLS_KEY_DIR"])
csr_dir = Path(os.environ["AUTO_TLS_CSR_DIR"])
cert_dir = Path(os.environ["AUTO_TLS_CERT_DIR"])
fullchain_dir = Path(os.environ["AUTO_TLS_FULLCHAIN_DIR"])
store_dir = Path(os.environ["AUTO_TLS_STORE_DIR"])
password_dir = Path(os.environ["AUTO_TLS_PASSWORD_DIR"])
ca_chain = Path(os.environ["AUTO_TLS_ISSUED_CA_CHAIN_FILE"])
csr_package = Path(os.environ["AUTO_TLS_CSR_PACKAGE_FILE"])
openssl_bin = os.environ["OPENSSL_BIN"]
keytool = os.environ["KEYTOOL"]
encrypt_keys = os.environ["AUTO_TLS_ENCRYPT_HOST_KEYS"] == "true"
host_key_password_file = Path(os.environ["AUTO_TLS_HOST_KEY_PASSWORD_FILE"])
keystore_password_file = Path(os.environ["AUTO_TLS_KEYSTORE_PASSWORD_FILE"])
keystore_password = os.environ["AUTO_TLS_KEYSTORE_PASSWORD"]
truststore_password = os.environ["AUTO_TLS_TRUSTSTORE_PASSWORD"]
store_type = os.environ["AUTO_TLS_STORE_TYPE"]
ca_alias = os.environ["AUTO_TLS_CA_STORE_ALIAS"]


def run(cmd, *, input_bytes=None, binary=False, quiet=True):
    result = subprocess.run(cmd, input=input_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=False)
    if result.returncode:
        print(result.stdout.decode(errors="replace"), end="")
        print(result.stderr.decode(errors="replace"), end="")
        raise SystemExit(f"[ERROR] Command failed: {' '.join(map(str, cmd))}")
    if not quiet:
        print(result.stdout.decode(errors="replace"), end="")
        print(result.stderr.decode(errors="replace"), end="")
    return result.stdout if binary else result.stdout.decode(errors="replace")


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


def pem_cert_blocks(text):
    return re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", text, flags=re.S)


def cert_hash_from_pem(pem_bytes):
    der = run([openssl_bin, "x509", "-outform", "DER"], input_bytes=pem_bytes, binary=True)
    return hashlib.sha256(der).hexdigest()


def cert_hash_from_file(path):
    der = run([openssl_bin, "x509", "-in", str(path), "-outform", "DER"], binary=True)
    return hashlib.sha256(der).hexdigest()


def pubkey_hash_from_key(path):
    cmd = [openssl_bin, "pkey", "-in", str(path)]
    if encrypt_keys:
        cmd += ["-passin", f"file:{host_key_password_file}"]
    cmd += ["-pubout", "-outform", "DER"]
    return hashlib.sha256(run(cmd, binary=True)).hexdigest()


def pubkey_hash_from_csr(path):
    pem = run([openssl_bin, "req", "-in", str(path), "-pubkey", "-noout"], binary=True)
    der = run([openssl_bin, "pkey", "-pubin", "-outform", "DER"], input_bytes=pem, binary=True)
    return hashlib.sha256(der).hexdigest()


def pubkey_hash_from_cert(path):
    pem = run([openssl_bin, "x509", "-in", str(path), "-pubkey", "-noout"], binary=True)
    der = run([openssl_bin, "pkey", "-pubin", "-outform", "DER"], input_bytes=pem, binary=True)
    return hashlib.sha256(der).hexdigest()


def ensure_private(path):
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        raise SystemExit(f"[ERROR] Sensitive file is group/world accessible: {path} mode={mode:04o}")


hosts = []
with hosts_csv.open(newline="") as f:
    reader = csv.DictReader(f)
    if not reader.fieldnames:
        raise SystemExit("[ERROR] hosts.csv has no header row")
    for row in reader:
        host_id = (row.get("host_id") or row.get("hostname") or row.get("host") or "").strip()
        if host_id and not host_id.startswith("#"):
            hosts.append(host_id)
if not hosts:
    raise SystemExit("[ERROR] No hosts found in hosts.csv")

chain_blocks = pem_cert_blocks(ca_chain.read_text())
if not chain_blocks:
    raise SystemExit(f"[ERROR] Empty CA chain: {ca_chain}")
chain_hashes = [cert_hash_from_pem((block + "\n").encode()) for block in chain_blocks]
chain_count = len(chain_blocks)

# Validate package paths, expected contents, and SHA256SUMS entirely in memory.
with tarfile.open(csr_package, "r:gz") as tf:
    members = [member for member in tf.getmembers() if member.isfile()]
    package_names = [member.name for member in members]
    for name in package_names:
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or not name.startswith("customer-csr-package/"):
            raise SystemExit(f"[ERROR] Unsafe path in CSR package: {name}")
    forbidden = [
        name for name in package_names
        if "key.pem" in name.lower()
        or "password" in name.lower()
        or name.lower().endswith(".pass")
        or "/private/" in name.lower()
    ]
    if forbidden:
        raise SystemExit(f"[ERROR] CSR package contains sensitive files: {forbidden}")
    contents = {}
    for member in members:
        extracted = tf.extractfile(member)
        if extracted is None:
            raise SystemExit(f"[ERROR] Could not read package member: {member.name}")
        contents[PurePosixPath(member.name).name] = extracted.read()

expected_names = {
    "README-CERTIFICATE-REQUEST.txt",
    "SHA256SUMS",
    "certificate-request-manifest.csv",
    *{f"{host}-csr.pem" for host in hosts},
}
if set(contents) != expected_names:
    missing = sorted(expected_names - set(contents))
    unexpected = sorted(set(contents) - expected_names)
    raise SystemExit(f"[ERROR] CSR package content mismatch. Missing={missing}, unexpected={unexpected}")

checksum_lines = contents["SHA256SUMS"].decode().splitlines()
checksums = {}
for line in checksum_lines:
    match = re.fullmatch(r"([0-9a-fA-F]{64})  (.+)", line.strip())
    if not match:
        raise SystemExit(f"[ERROR] Invalid SHA256SUMS line in CSR package: {line!r}")
    checksums[match.group(2)] = match.group(1).lower()
for name in expected_names - {"SHA256SUMS"}:
    actual = hashlib.sha256(contents[name]).hexdigest()
    if checksums.get(name) != actual:
        raise SystemExit(f"[ERROR] CSR package checksum mismatch for {name}")
for host in hosts:
    local_csr = csr_dir / f"{host}-csr.pem"
    if hashlib.sha256(local_csr.read_bytes()).hexdigest() != hashlib.sha256(contents[local_csr.name]).hexdigest():
        raise SystemExit(f"[ERROR] Packaged CSR does not match local CSR for {host}")
print(f"[PASS] CSR handoff package contains {len(contents)} expected public file(s), valid checksums, and no secrets")

required_secret_files = [Path(os.environ["AUTO_TLS_KEYSTORE_PASSWORD_FILE"]), Path(os.environ["AUTO_TLS_TRUSTSTORE_PASSWORD_FILE"])]
if encrypt_keys:
    required_secret_files.append(host_key_password_file)
for path in required_secret_files:
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f"[ERROR] Missing password file: {path}")
    ensure_private(path)
for path in password_dir.glob("*.pass"):
    ensure_private(path)
print("[PASS] Password files exist and have private permissions")

validated = 0
for host_id in hosts:
    key = key_dir / f"{host_id}-key.pem"
    csr = csr_dir / f"{host_id}-csr.pem"
    cert = cert_dir / f"{host_id}-cert.pem"
    fullchain = fullchain_dir / f"{host_id}-fullchain.pem"
    keystore = store_dir / f"{host_id}-keystore.p12"
    truststore = store_dir / f"{host_id}-truststore.p12"
    for path, label in (
        (key, "private key"), (csr, "CSR"), (cert, "certificate"),
        (fullchain, "fullchain"), (keystore, "keystore"), (truststore, "truststore"),
    ):
        if not path.is_file() or path.stat().st_size == 0:
            raise SystemExit(f"[ERROR] Missing or empty {label} for {host_id}: {path}")

    ensure_private(key)
    assert_key_protection_mode(key, host_id)
    ensure_private(keystore)
    ensure_private(truststore)

    hashes = {pubkey_hash_from_key(key), pubkey_hash_from_csr(csr), pubkey_hash_from_cert(cert)}
    if len(hashes) != 1:
        raise SystemExit(f"[ERROR] Key/CSR/certificate mismatch for {host_id}")
    run([openssl_bin, "verify", "-CAfile", str(ca_chain), str(cert)])

    fullchain_blocks = pem_cert_blocks(fullchain.read_text())
    if len(fullchain_blocks) != chain_count + 1:
        raise SystemExit(
            f"[ERROR] Fullchain for {host_id} has {len(fullchain_blocks)} certificate(s); expected {chain_count + 1}"
        )
    fullchain_hashes = [cert_hash_from_pem((block + "\n").encode()) for block in fullchain_blocks]
    expected_fullchain_hashes = [cert_hash_from_file(cert), *chain_hashes]
    if fullchain_hashes != expected_fullchain_hashes:
        raise SystemExit(f"[ERROR] Fullchain certificate order/content is incorrect for {host_id}")

    extracted_leaf = run([
        openssl_bin, "pkcs12", "-in", str(keystore),
        "-clcerts", "-nokeys", "-passin", f"file:{keystore_password_file}",
    ], binary=True)
    if cert_hash_from_pem(extracted_leaf) != cert_hash_from_file(cert):
        raise SystemExit(f"[ERROR] Keystore leaf certificate does not match issued certificate for {host_id}")

    extracted_key = run([
        openssl_bin, "pkcs12", "-in", str(keystore),
        "-nocerts", "-nodes", "-passin", f"file:{keystore_password_file}",
    ], binary=True)
    extracted_key_der = run(
        [openssl_bin, "pkey", "-pubout", "-outform", "DER"],
        input_bytes=extracted_key,
        binary=True,
    )
    if hashlib.sha256(extracted_key_der).hexdigest() != pubkey_hash_from_key(key):
        raise SystemExit(f"[ERROR] Keystore private key does not match host private key for {host_id}")

    truststore_rfc = run([
        keytool, "-list", "-rfc", "-keystore", str(truststore),
        "-storetype", store_type, "-storepass", truststore_password,
    ])
    if truststore_rfc.count("-----BEGIN CERTIFICATE-----") != chain_count:
        raise SystemExit(f"[ERROR] Truststore for {host_id} does not contain exactly the full CA chain")
    for index, expected_hash in enumerate(chain_hashes, 1):
        alias = f"{ca_alias}-{index}"
        exported = run([
            keytool, "-exportcert", "-rfc", "-alias", alias,
            "-keystore", str(truststore), "-storetype", store_type,
            "-storepass", truststore_password,
        ], binary=True)
        if cert_hash_from_pem(exported) != expected_hash:
            raise SystemExit(f"[ERROR] Truststore alias {alias} does not match CA chain entry {index} for {host_id}")

    run([
        keytool, "-list", "-v", "-keystore", str(keystore),
        "-storetype", store_type, "-storepass", keystore_password,
    ])
    print(f"[PASS] Final artifacts validated for {host_id}")
    validated += 1

if validated < 1:
    raise SystemExit("[ERROR] No host artifacts were validated")
print(f"[OK] Final artifact validation passed for {validated} host(s)")
PY

chmod "${AUTO_TLS_FILE_MODE}" "${AUTO_TLS_VALIDATION_REPORT_FILE}"
apply_owner_if_available

echo "[OK] Final artifact validation completed"
echo "[INFO] Report: ${AUTO_TLS_VALIDATION_REPORT_FILE}"
