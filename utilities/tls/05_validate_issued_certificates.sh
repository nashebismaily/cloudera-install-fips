#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

ensure_hosts_csv
require_file "${AUTO_TLS_ISSUED_CA_CHAIN_FILE}"
require_cmd "${OPENSSL_BIN}"
prepare_dirs

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
openssl_dir = Path(os.environ["AUTO_TLS_OPENSSL_DIR"])
ca_chain = Path(os.environ["AUTO_TLS_ISSUED_CA_CHAIN_FILE"])
openssl_bin = os.environ["OPENSSL_BIN"]
encrypt_keys = os.environ["AUTO_TLS_ENCRYPT_HOST_KEYS"] == "true"
host_key_password_file = Path(os.environ["AUTO_TLS_HOST_KEY_PASSWORD_FILE"])
min_validity_seconds = int(os.environ["AUTO_TLS_MIN_CERT_VALIDITY_DAYS"]) * 86400
require_cn_match = os.environ["AUTO_TLS_REQUIRE_CN_MATCH"] == "true"
disallow_wildcards = os.environ["AUTO_TLS_DISALLOW_WILDCARDS"] == "true"
min_rsa_bits = int(os.environ["AUTO_TLS_MIN_RSA_BITS"])
expected_key_algorithm = os.environ["AUTO_TLS_KEY_ALGORITHM"].upper()


def run(cmd, *, input_bytes=None, binary=False, quiet=False):
    result = subprocess.run(
        cmd,
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=False,
    )
    if result.returncode:
        if result.stdout:
            print(result.stdout.decode(errors="replace"), end="")
        if result.stderr:
            print(result.stderr.decode(errors="replace"), end="")
        raise SystemExit(f"[ERROR] Command failed: {' '.join(map(str, cmd))}")
    if not quiet and result.stdout:
        print(result.stdout.decode(errors="replace"), end="")
    if not quiet and result.stderr:
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


def split_list(value):
    if not value:
        return []
    items = []
    for item in value.replace(",", ";").split(";"):
        item = item.strip()
        if item and item not in items:
            items.append(item)
    return items


def pubkey_hash_from_key(path):
    cmd = [openssl_bin, "pkey", "-in", str(path)]
    if encrypt_keys:
        cmd += ["-passin", f"file:{host_key_password_file}"]
    cmd += ["-pubout", "-outform", "DER"]
    return hashlib.sha256(run(cmd, binary=True, quiet=True)).hexdigest()


def pubkey_hash_from_csr(path):
    pem = run([openssl_bin, "req", "-in", str(path), "-pubkey", "-noout"], binary=True, quiet=True)
    der = run([openssl_bin, "pkey", "-pubin", "-outform", "DER"], input_bytes=pem, binary=True, quiet=True)
    return hashlib.sha256(der).hexdigest()


def pubkey_hash_from_cert(path):
    pem = run([openssl_bin, "x509", "-in", str(path), "-pubkey", "-noout"], binary=True, quiet=True)
    der = run([openssl_bin, "pkey", "-pubin", "-outform", "DER"], input_bytes=pem, binary=True, quiet=True)
    return hashlib.sha256(der).hexdigest()


def certificate_fingerprint(path):
    der = run([openssl_bin, "x509", "-in", str(path), "-outform", "DER"], binary=True, quiet=True)
    return hashlib.sha256(der).hexdigest()


def parse_sans_from_text(output, source):
    dns = set(re.findall(r"DNS:([^,\s]+)", output))
    ips = set()
    for value in re.findall(r"IP Address:([^,\s]+)", output):
        try:
            ips.add(str(ipaddress.ip_address(value)))
        except ValueError:
            raise SystemExit(f"[ERROR] {source} contains invalid IP SAN {value}")
    return dns, ips


def parse_cert_sans(cert):
    output = run([openssl_bin, "x509", "-in", str(cert), "-noout", "-ext", "subjectAltName"], quiet=True)
    return parse_sans_from_text(output, str(cert))


def parse_csr_sans(csr):
    output = run([openssl_bin, "req", "-in", str(csr), "-noout", "-text"], quiet=True)
    return parse_sans_from_text(output, str(csr))


def rfc2253_name(path, field):
    output = run([openssl_bin, "x509", "-in", str(path), "-noout", f"-{field}", "-nameopt", "RFC2253"], quiet=True).strip()
    prefix = f"{field}="
    return output[len(prefix):] if output.startswith(prefix) else output


def exact_cn(subject):
    match = re.search(r"(?:^|,)CN=([^,]+)", subject)
    return match.group(1) if match else ""


def required_extension_labels(config_value, mapping):
    labels = []
    for token in config_value.split(","):
        token = token.strip()
        if not token or token == "critical":
            continue
        labels.append(mapping.get(token, token))
    return labels


def validate_public_key_strength(cert, host_id):
    pub_pem = run([openssl_bin, "x509", "-in", str(cert), "-pubkey", "-noout"], binary=True, quiet=True)
    text = run([openssl_bin, "pkey", "-pubin", "-text", "-noout"], input_bytes=pub_pem, quiet=True)
    if expected_key_algorithm == "RSA":
        match = re.search(r"(?:Public-Key|Private-Key): \((\d+) bit\)", text)
        if not match:
            raise SystemExit(f"[ERROR] Expected an RSA certificate key for {host_id}, but could not identify RSA key size")
        bits = int(match.group(1))
        if bits < min_rsa_bits:
            raise SystemExit(f"[ERROR] RSA key for {host_id} is only {bits} bits; minimum is {min_rsa_bits}")


chain_text = ca_chain.read_text()
if "PRIVATE KEY" in chain_text:
    raise SystemExit(f"[ERROR] CA chain contains a private key: {ca_chain}")
chain_blocks = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", chain_text, flags=re.S)
if not chain_blocks:
    raise SystemExit(f"[ERROR] No PEM certificates found in CA chain: {ca_chain}")
if chain_text.count("-----BEGIN CERTIFICATE-----") != chain_text.count("-----END CERTIFICATE-----"):
    raise SystemExit(f"[ERROR] Malformed PEM certificate chain: {ca_chain}")

chain_split_dir = openssl_dir / "issued-ca-chain"
chain_split_dir.mkdir(parents=True, exist_ok=True)
for old in chain_split_dir.glob("*.pem"):
    old.unlink()
chain_paths = []
seen_ca_fingerprints = set()
for index, block in enumerate(chain_blocks, 1):
    path = chain_split_dir / f"ca-{index}.pem"
    path.write_text(block + "\n")
    path.chmod(0o644)
    run([openssl_bin, "x509", "-in", str(path), "-noout"], quiet=True)
    run([openssl_bin, "x509", "-in", str(path), "-checkend", str(min_validity_seconds), "-noout"], quiet=True)
    basic = run([openssl_bin, "x509", "-in", str(path), "-noout", "-ext", "basicConstraints"], quiet=True)
    if "CA:TRUE" not in basic:
        raise SystemExit(f"[ERROR] CA chain entry {index} is not a CA certificate")
    key_usage = run([openssl_bin, "x509", "-in", str(path), "-noout", "-ext", "keyUsage"], quiet=True)
    if "X509v3 Key Usage" in key_usage and "Certificate Sign" not in key_usage:
        raise SystemExit(f"[ERROR] CA chain entry {index} has Key Usage but lacks Certificate Sign")
    fp = certificate_fingerprint(path)
    if fp in seen_ca_fingerprints:
        raise SystemExit(f"[ERROR] Duplicate certificate found in CA chain at entry {index}")
    seen_ca_fingerprints.add(fp)
    chain_paths.append(path)
    run([openssl_bin, "x509", "-in", str(path), "-noout", "-subject", "-issuer", "-dates"], quiet=False)

# Enforce the documented order: issuing intermediate first and root last.
for index in range(len(chain_paths) - 1):
    current = chain_paths[index]
    issuer = chain_paths[index + 1]
    current_issuer = rfc2253_name(current, "issuer")
    issuer_subject = rfc2253_name(issuer, "subject")
    if current_issuer != issuer_subject:
        raise SystemExit(
            f"[ERROR] CA chain is out of order or broken between entries {index + 1} and {index + 2}: "
            f"issuer={current_issuer!r}, next subject={issuer_subject!r}"
        )
    run([openssl_bin, "verify", "-CAfile", str(issuer), str(current)], quiet=True)
root_path = chain_paths[-1]
root_subject = rfc2253_name(root_path, "subject")
root_issuer = rfc2253_name(root_path, "issuer")
if root_subject != root_issuer:
    raise SystemExit("[ERROR] Last certificate in ca-chain.pem must be a self-signed root CA")
run([openssl_bin, "verify", "-CAfile", str(root_path), str(root_path)], quiet=True)

untrusted_bundle = chain_split_dir / "untrusted-intermediates.pem"
if len(chain_paths) > 1:
    untrusted_bundle.write_text("".join(path.read_text() for path in chain_paths[:-1]))
    untrusted_bundle.chmod(0o644)
print(f"[PASS] CA chain contains {len(chain_blocks)} linked, ordered CA certificate(s)")

key_usage_map = {
    "digitalSignature": "Digital Signature",
    "nonRepudiation": "Non Repudiation",
    "contentCommitment": "Non Repudiation",
    "keyEncipherment": "Key Encipherment",
    "dataEncipherment": "Data Encipherment",
    "keyAgreement": "Key Agreement",
    "keyCertSign": "Certificate Sign",
    "cRLSign": "CRL Sign",
}
eku_map = {
    "serverAuth": "TLS Web Server Authentication",
    "clientAuth": "TLS Web Client Authentication",
    "codeSigning": "Code Signing",
    "emailProtection": "E-mail Protection",
    "timeStamping": "Time Stamping",
    "OCSPSigning": "OCSP Signing",
}
required_ku = required_extension_labels(os.environ["AUTO_TLS_KEY_USAGE"], key_usage_map)
required_eku = required_extension_labels(os.environ["AUTO_TLS_EXTENDED_KEY_USAGE"], eku_map)

seen_serials = set()
seen_leaf_fingerprints = set()
validated = 0
with hosts_csv.open(newline="") as f:
    reader = csv.DictReader(f)
    if not reader.fieldnames:
        raise SystemExit("[ERROR] hosts.csv has no header row")
    for row in reader:
        host_id = (row.get("host_id") or row.get("hostname") or row.get("host") or "").strip()
        if not host_id or host_id.startswith("#"):
            continue
        common_name = (row.get("common_name") or row.get("cn") or host_id).strip()
        key = key_dir / f"{host_id}-key.pem"
        csr = csr_dir / f"{host_id}-csr.pem"
        cert = cert_dir / f"{host_id}-cert.pem"
        fullchain = fullchain_dir / f"{host_id}-fullchain.pem"

        for path, label in ((key, "private key"), (csr, "CSR"), (cert, "issued certificate")):
            if not path.is_file() or path.stat().st_size == 0:
                raise SystemExit(f"[ERROR] Missing {label} for {host_id}: {path}")

        cert_text = cert.read_text()
        if len(re.findall(r"-----BEGIN CERTIFICATE-----", cert_text)) != 1:
            raise SystemExit(f"[ERROR] {cert} must contain exactly one PEM leaf certificate; put CA certificates in ca-chain.pem")
        if "PRIVATE KEY" in cert_text:
            raise SystemExit(f"[ERROR] Issued certificate file contains a private key: {cert}")

        assert_key_protection_mode(key, host_id)
        run([openssl_bin, "req", "-in", str(csr), "-verify", "-noout"], quiet=True)
        run([openssl_bin, "x509", "-in", str(cert), "-noout"], quiet=True)

        hashes = {pubkey_hash_from_key(key), pubkey_hash_from_csr(csr), pubkey_hash_from_cert(cert)}
        if len(hashes) != 1:
            raise SystemExit(f"[ERROR] Private key, CSR, and returned certificate do not match for {host_id}")

        leaf_issuer = rfc2253_name(cert, "issuer")
        first_ca_subject = rfc2253_name(chain_paths[0], "subject")
        if leaf_issuer != first_ca_subject:
            raise SystemExit(
                f"[ERROR] Leaf certificate for {host_id} was not issued by the first certificate in ca-chain.pem: "
                f"leaf issuer={leaf_issuer!r}, first CA subject={first_ca_subject!r}"
            )

        verify_cmd = [openssl_bin, "verify", "-CAfile", str(root_path)]
        if len(chain_paths) > 1:
            verify_cmd += ["-untrusted", str(untrusted_bundle)]
        run(verify_cmd + [str(cert)], quiet=False)
        run(verify_cmd + ["-purpose", "sslserver", str(cert)], quiet=True)
        run(verify_cmd + ["-purpose", "sslclient", str(cert)], quiet=True)
        run([openssl_bin, "x509", "-in", str(cert), "-checkend", str(min_validity_seconds), "-noout"], quiet=True)
        validate_public_key_strength(cert, host_id)

        subject = rfc2253_name(cert, "subject")
        actual_cn = exact_cn(subject)
        if require_cn_match and actual_cn != common_name:
            raise SystemExit(f"[ERROR] Certificate CN does not match expected common_name={common_name}: CN={actual_cn!r}")
        if disallow_wildcards and "*" in subject:
            raise SystemExit(f"[ERROR] Wildcard certificate subject is not allowed for {host_id}: {subject}")

        expected_dns = set(split_list(row.get("dns_sans")))
        expected_ips = {str(ipaddress.ip_address(value)) for value in split_list(row.get("ip_sans"))}
        try:
            expected_ips.add(str(ipaddress.ip_address(host_id)))
        except ValueError:
            expected_dns.add(host_id)
        if common_name:
            try:
                expected_ips.add(str(ipaddress.ip_address(common_name)))
            except ValueError:
                expected_dns.add(common_name)

        csr_dns, csr_ips = parse_csr_sans(csr)
        expected_dns.update(csr_dns)
        expected_ips.update(csr_ips)
        actual_dns, actual_ips = parse_cert_sans(cert)
        if disallow_wildcards and any("*" in value for value in actual_dns):
            raise SystemExit(f"[ERROR] Wildcard DNS SAN is not allowed for {host_id}: {sorted(actual_dns)}")
        missing_dns = sorted(expected_dns - actual_dns)
        missing_ips = sorted(expected_ips - actual_ips)
        if missing_dns or missing_ips:
            raise SystemExit(f"[ERROR] Missing SANs for {host_id}; DNS={missing_dns}, IP={missing_ips}")

        basic = run([openssl_bin, "x509", "-in", str(cert), "-noout", "-ext", "basicConstraints"], quiet=True)
        if "CA:FALSE" not in basic:
            raise SystemExit(f"[ERROR] Leaf certificate must contain CA:FALSE for {host_id}")
        ku = run([openssl_bin, "x509", "-in", str(cert), "-noout", "-ext", "keyUsage"], quiet=True)
        eku = run([openssl_bin, "x509", "-in", str(cert), "-noout", "-ext", "extendedKeyUsage"], quiet=True)
        for label in required_ku:
            if label not in ku:
                raise SystemExit(f"[ERROR] Missing key usage {label!r} for {host_id}")
        for label in required_eku:
            if label not in eku:
                raise SystemExit(f"[ERROR] Missing extended key usage {label!r} for {host_id}")

        serial = run([openssl_bin, "x509", "-in", str(cert), "-noout", "-serial"], quiet=True).strip()
        if serial in seen_serials:
            raise SystemExit(f"[ERROR] Duplicate certificate serial detected: {serial}")
        seen_serials.add(serial)
        fingerprint = certificate_fingerprint(cert)
        if fingerprint in seen_leaf_fingerprints:
            raise SystemExit(f"[ERROR] The same leaf certificate was returned for more than one host: {host_id}")
        seen_leaf_fingerprints.add(fingerprint)

        fullchain.write_text(cert_text.rstrip() + "\n" + chain_text.lstrip())
        fullchain.chmod(0o644)
        cert.chmod(0o644)
        print(f"[PASS] Issued certificate validated for {host_id}")
        validated += 1

if validated < 1:
    raise SystemExit("[ERROR] No host certificates were validated")
print(f"[OK] Validated {validated} issued certificate(s) and built full chains")
PY

chmod "${AUTO_TLS_PUBLIC_FILE_MODE}" \
  "${AUTO_TLS_ISSUED_CA_CHAIN_FILE}" \
  "${AUTO_TLS_CERT_DIR}"/*-cert.pem \
  "${AUTO_TLS_FULLCHAIN_DIR}"/*-fullchain.pem
apply_owner_if_available

echo "[OK] Issued certificate validation completed"
