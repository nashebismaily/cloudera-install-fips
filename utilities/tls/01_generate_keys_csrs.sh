#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_var AUTO_TLS_HOSTS_CSV
require_var AUTO_TLS_COUNTRY
require_var AUTO_TLS_STATE
require_var AUTO_TLS_LOCALITY
require_var AUTO_TLS_ORG
require_var AUTO_TLS_ORG_UNIT
ensure_hosts_csv
require_cmd "${OPENSSL_BIN}"
prepare_dirs

if [[ "${AUTO_TLS_ENCRYPT_HOST_KEYS}" == "true" ]]; then
  require_file "${AUTO_TLS_HOST_KEY_PASSWORD_FILE}"
fi

echo "[INFO] Generating or validating private keys and CSRs"
echo "[INFO] Inventory: ${AUTO_TLS_HOSTS_CSV}"
echo "[INFO] Private keys: ${AUTO_TLS_KEY_DIR}"
echo "[INFO] Customer request folder: ${AUTO_TLS_CSR_DIR}"
echo "[INFO] Host private-key mode: $(host_key_mode_label)"
echo "[INFO] AUTO_TLS_ENCRYPT_HOST_KEYS=${AUTO_TLS_ENCRYPT_HOST_KEYS}"
echo "[INFO] Overwrite existing keys: ${AUTO_TLS_OVERWRITE_KEYS}"

"${SYSTEM_PYTHON_BIN}" - <<'PY'
import csv
import hashlib
import ipaddress
import os
import re
import subprocess
from pathlib import Path

hosts_csv = Path(os.environ["AUTO_TLS_HOSTS_CSV"])
key_dir = Path(os.environ["AUTO_TLS_KEY_DIR"])
csr_dir = Path(os.environ["AUTO_TLS_CSR_DIR"])
cert_dir = Path(os.environ["AUTO_TLS_CERT_DIR"])
fullchain_dir = Path(os.environ["AUTO_TLS_FULLCHAIN_DIR"])
store_dir = Path(os.environ["AUTO_TLS_STORE_DIR"])
openssl_dir = Path(os.environ["AUTO_TLS_OPENSSL_DIR"])
openssl_bin = os.environ["OPENSSL_BIN"]
encrypt_keys = os.environ["AUTO_TLS_ENCRYPT_HOST_KEYS"] == "true"
overwrite = os.environ["AUTO_TLS_OVERWRITE_KEYS"] == "true"
disallow_wildcards = os.environ["AUTO_TLS_DISALLOW_WILDCARDS"] == "true"
host_key_password_file = Path(os.environ["AUTO_TLS_HOST_KEY_PASSWORD_FILE"])

safe_file_id = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$")
safe_dn_value = re.compile(r"^[A-Za-z0-9 ._@()/&+-]+$")
safe_dns = re.compile(r"^(?:\*\.)?[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$")


def run(cmd, *, input_bytes=None, binary=False, quiet=False):
    printable = []
    redact_next = False
    for item in map(str, cmd):
        if redact_next:
            printable.append("[REDACTED]")
            redact_next = False
        else:
            printable.append(item)
            if item in {"-pass", "-passin", "-passout"}:
                redact_next = True
    if not quiet:
        print("[DEBUG] " + " ".join(printable))
    result = subprocess.run(
        cmd,
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=not binary,
    )
    if result.stdout and not quiet and not binary:
        print(result.stdout, end="")
    if result.stderr and (result.returncode or not quiet):
        if binary:
            print(result.stderr.decode(errors="replace"), end="")
        else:
            print(result.stderr, end="")
    if result.returncode:
        raise SystemExit(f"[ERROR] Command failed with return code {result.returncode}")
    return result.stdout


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


def split_list(value):
    if not value:
        return []
    items = []
    for item in value.replace(",", ";").split(";"):
        item = item.strip()
        if item and item not in items:
            items.append(item)
    return items


def is_ip(value):
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return False


def validate_host_id(host_id):
    if not safe_file_id.fullmatch(host_id) or ".." in host_id:
        raise SystemExit(
            f"[ERROR] Unsafe host_id {host_id!r}. Use a hostname or IP containing only letters, numbers, dots, underscores, and hyphens."
        )


def validate_dn(name, value):
    if not value or not safe_dn_value.fullmatch(value) or "\n" in value or "\r" in value:
        raise SystemExit(f"[ERROR] Unsafe or empty certificate subject value for {name}: {value!r}")


def validate_dns(value, host_id):
    if not safe_dns.fullmatch(value):
        raise SystemExit(f"[ERROR] Invalid DNS SAN for {host_id}: {value}")
    if disallow_wildcards and "*" in value:
        raise SystemExit(f"[ERROR] Wildcard DNS SANs are disabled for this workflow: {value}")


def public_key_digest_from_key(path):
    cmd = [openssl_bin, "pkey", "-in", str(path)]
    if encrypt_keys:
        cmd += ["-passin", f"file:{host_key_password_file}"]
    cmd += ["-pubout", "-outform", "DER"]
    return hashlib.sha256(run(cmd, binary=True, quiet=True)).hexdigest()


def public_key_digest_from_csr(path):
    pem = run([openssl_bin, "req", "-in", str(path), "-pubkey", "-noout"], binary=True, quiet=True)
    der = run([openssl_bin, "pkey", "-pubin", "-outform", "DER"], input_bytes=pem, binary=True, quiet=True)
    return hashlib.sha256(der).hexdigest()


def parse_csr_sans(path):
    text = run([openssl_bin, "req", "-in", str(path), "-noout", "-text"], quiet=True)
    dns = set(re.findall(r"DNS:([^,\s]+)", text))
    ips = set()
    for item in re.findall(r"IP Address:([^,\s]+)", text):
        ips.add(str(ipaddress.ip_address(item)))
    return dns, ips


def validate_existing(host_id, key_file, csr_file, expected_dns, expected_ips):
    assert_key_protection_mode(key_file, host_id)
    run([openssl_bin, "req", "-in", str(csr_file), "-verify", "-noout"], quiet=True)
    if public_key_digest_from_key(key_file) != public_key_digest_from_csr(csr_file):
        raise SystemExit(f"[ERROR] Existing CSR does not match existing private key for {host_id}")
    actual_dns, actual_ips = parse_csr_sans(csr_file)
    missing_dns = sorted(set(expected_dns) - actual_dns)
    missing_ips = sorted(set(expected_ips) - actual_ips)
    if missing_dns or missing_ips:
        raise SystemExit(
            f"[ERROR] Existing CSR for {host_id} does not match hosts.csv. Missing DNS SANs={missing_dns}, IP SANs={missing_ips}. "
            "Set AUTO_TLS_OVERWRITE_KEYS=true only if replacing the key/CSR is intentional."
        )
    mode = "encrypted/password-protected" if encrypt_keys else "unencrypted/no-password"
    print(f"[PASS] Reusing existing matching {mode} key and CSR for {host_id}")


for subject_name in ("AUTO_TLS_COUNTRY", "AUTO_TLS_STATE", "AUTO_TLS_LOCALITY", "AUTO_TLS_ORG", "AUTO_TLS_ORG_UNIT"):
    validate_dn(subject_name, os.environ[subject_name])

seen = set()
processed = 0
with hosts_csv.open(newline="") as f:
    reader = csv.DictReader(f)
    if not reader.fieldnames:
        raise SystemExit("[ERROR] hosts.csv has no header row")

    for row_number, row in enumerate(reader, start=2):
        host_id = (row.get("host_id") or row.get("hostname") or row.get("host") or "").strip()
        if not host_id or host_id.startswith("#"):
            continue
        validate_host_id(host_id)
        if host_id in seen:
            raise SystemExit(f"[ERROR] Duplicate host_id at line {row_number}: {host_id}")
        seen.add(host_id)

        common_name = (row.get("common_name") or row.get("cn") or host_id).strip()
        if is_ip(common_name):
            common_name = str(ipaddress.ip_address(common_name))
        else:
            validate_dns(common_name, host_id)

        dns_sans = split_list(row.get("dns_sans"))
        ip_sans = split_list(row.get("ip_sans"))
        for dns in dns_sans:
            validate_dns(dns, host_id)

        if is_ip(host_id):
            host_id = str(ipaddress.ip_address(host_id))
            if host_id not in ip_sans:
                ip_sans.append(host_id)
        elif host_id not in dns_sans:
            dns_sans.append(host_id)

        if common_name:
            if is_ip(common_name):
                if common_name not in ip_sans:
                    ip_sans.append(common_name)
            elif common_name not in dns_sans:
                dns_sans.append(common_name)

        normalized_ips = []
        for value in ip_sans:
            try:
                normalized = str(ipaddress.ip_address(value))
            except ValueError:
                raise SystemExit(f"[ERROR] Invalid IP SAN for {host_id}: {value}")
            if normalized not in normalized_ips:
                normalized_ips.append(normalized)
        ip_sans = normalized_ips

        if not dns_sans and not ip_sans:
            raise SystemExit(f"[ERROR] No SAN entries found for {host_id}")

        key_file = key_dir / f"{host_id}-key.pem"
        csr_file = csr_dir / f"{host_id}-csr.pem"
        conf_file = openssl_dir / f"{host_id}-openssl.cnf"
        tmp_key = Path(str(key_file) + ".tmp")
        tmp_csr = Path(str(csr_file) + ".tmp")

        if key_file.exists() or csr_file.exists():
            if not (key_file.is_file() and csr_file.is_file()):
                raise SystemExit(
                    f"[ERROR] Incomplete existing key/CSR pair for {host_id}. Key={key_file.exists()} CSR={csr_file.exists()}"
                )
            if not overwrite:
                validate_existing(host_id, key_file, csr_file, dns_sans, ip_sans)
                processed += 1
                continue
            print(f"[WARN] Replacing existing private key and CSR for {host_id}")
            for stale in (
                key_file,
                csr_file,
                cert_dir / f"{host_id}-cert.pem",
                fullchain_dir / f"{host_id}-fullchain.pem",
                store_dir / f"{host_id}-keystore.p12",
                store_dir / f"{host_id}-truststore.p12",
            ):
                if stale.exists():
                    stale.unlink()

        for stale in (tmp_key, tmp_csr):
            if stale.exists():
                stale.unlink()

        alt_lines = [f"DNS.{i} = {value}" for i, value in enumerate(dns_sans, 1)]
        alt_lines += [f"IP.{i} = {value}" for i, value in enumerate(ip_sans, 1)]

        conf = f"""[ req ]
default_bits = {os.environ['AUTO_TLS_KEY_SIZE']}
prompt = no
default_md = {os.environ['AUTO_TLS_DIGEST']}
distinguished_name = dn
req_extensions = req_ext

[ dn ]
C = {os.environ['AUTO_TLS_COUNTRY']}
ST = {os.environ['AUTO_TLS_STATE']}
L = {os.environ['AUTO_TLS_LOCALITY']}
O = {os.environ['AUTO_TLS_ORG']}
OU = {os.environ['AUTO_TLS_ORG_UNIT']}
CN = {common_name}

[ req_ext ]
subjectAltName = @alt_names
basicConstraints = {os.environ['AUTO_TLS_HOST_BASIC_CONSTRAINTS']}
keyUsage = {os.environ['AUTO_TLS_KEY_USAGE']}
extendedKeyUsage = {os.environ['AUTO_TLS_EXTENDED_KEY_USAGE']}

[ alt_names ]
{chr(10).join(alt_lines)}
"""
        conf_file.write_text(conf)
        conf_file.chmod(0o640)

        gen_cmd = [
            openssl_bin, "genpkey",
            "-algorithm", os.environ["AUTO_TLS_KEY_ALGORITHM"],
            "-pkeyopt", os.environ["AUTO_TLS_KEYGEN_PKEYOPT"],
        ]
        if encrypt_keys:
            gen_cmd += [f"-{os.environ['AUTO_TLS_PRIVATE_KEY_CIPHER']}", "-pass", f"file:{host_key_password_file}"]
        gen_cmd += ["-out", str(tmp_key)]
        run(gen_cmd)

        key_check = [openssl_bin, "pkey", "-in", str(tmp_key), "-check", "-noout"]
        if encrypt_keys:
            key_check += ["-passin", f"file:{host_key_password_file}"]
        run(key_check)
        assert_key_protection_mode(tmp_key, host_id)

        csr_cmd = [openssl_bin, "req", "-new", "-key", str(tmp_key)]
        if encrypt_keys:
            csr_cmd += ["-passin", f"file:{host_key_password_file}"]
        csr_cmd += ["-out", str(tmp_csr), "-config", str(conf_file)]
        run(csr_cmd)
        run([openssl_bin, "req", "-in", str(tmp_csr), "-verify", "-noout"])

        tmp_key.replace(key_file)
        tmp_csr.replace(csr_file)
        key_file.chmod(0o600)
        csr_file.chmod(0o644)

        if public_key_digest_from_key(key_file) != public_key_digest_from_csr(csr_file):
            raise SystemExit(f"[ERROR] Generated CSR does not match private key for {host_id}")

        mode = "encrypted" if encrypt_keys else "unencrypted"
        print(f"[OK] Created {mode} private key: {key_file}")
        print(f"[OK] Created CSR: {csr_file}")
        processed += 1

if processed < 1:
    raise SystemExit("[ERROR] No hosts were found in hosts.csv")
print(f"[OK] Processed {processed} key/CSR pair(s)")
PY

apply_owner_if_available
chmod "${AUTO_TLS_PRIVATE_FILE_MODE}" "${AUTO_TLS_KEY_DIR}"/*-key.pem
chmod "${AUTO_TLS_PUBLIC_FILE_MODE}" "${AUTO_TLS_CSR_DIR}"/*-csr.pem

echo "[OK] Key and CSR generation/validation completed"
