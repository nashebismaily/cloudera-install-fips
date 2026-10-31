#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

[[ "${AUTO_TLS_CERT_MODE}" == "test" ]] || fail "04_sign_csrs_with_test_ca.sh is only allowed when AUTO_TLS_CERT_MODE=test"
ensure_hosts_csv
require_file "${AUTO_TLS_TEST_CA_KEY_FILE}"
require_file "${AUTO_TLS_TEST_CA_CERT_FILE}"
require_file "${AUTO_TLS_TEST_CA_KEY_PASSWORD_FILE}"
require_cmd "${OPENSSL_BIN}"
prepare_dirs

if [[ -f "${AUTO_TLS_ISSUED_CA_CHAIN_FILE}" ]] && ! cmp -s "${AUTO_TLS_TEST_CA_CERT_FILE}" "${AUTO_TLS_ISSUED_CA_CHAIN_FILE}"; then
  [[ "${AUTO_TLS_OVERWRITE_ISSUED_CERTS}" == "true" ]] \
    || fail "A different issued/ca-chain.pem already exists. Set AUTO_TLS_OVERWRITE_ISSUED_CERTS=true only for an intentional test reset."
fi
cp -f "${AUTO_TLS_TEST_CA_CERT_FILE}" "${AUTO_TLS_ISSUED_CA_CHAIN_FILE}"
chmod "${AUTO_TLS_PUBLIC_FILE_MODE}" "${AUTO_TLS_ISSUED_CA_CHAIN_FILE}"

"${SYSTEM_PYTHON_BIN}" - <<'PY'
import csv
import hashlib
import ipaddress
import os
import subprocess
from pathlib import Path

hosts_csv = Path(os.environ["AUTO_TLS_HOSTS_CSV"])
csr_dir = Path(os.environ["AUTO_TLS_CSR_DIR"])
cert_dir = Path(os.environ["AUTO_TLS_CERT_DIR"])
openssl_dir = Path(os.environ["AUTO_TLS_OPENSSL_DIR"])
ca_key = Path(os.environ["AUTO_TLS_TEST_CA_KEY_FILE"])
ca_cert = Path(os.environ["AUTO_TLS_TEST_CA_CERT_FILE"])
ca_serial = Path(os.environ["AUTO_TLS_TEST_CA_SERIAL_FILE"])
ca_password_file = Path(os.environ["AUTO_TLS_TEST_CA_KEY_PASSWORD_FILE"])
openssl_bin = os.environ["OPENSSL_BIN"]
overwrite = os.environ["AUTO_TLS_OVERWRITE_ISSUED_CERTS"] == "true"


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


def split_list(value):
    if not value:
        return []
    values = []
    for item in value.replace(",", ";").split(";"):
        item = item.strip()
        if item and item not in values:
            values.append(item)
    return values


def pubkey_hash_from_csr(path):
    pem = run([openssl_bin, "req", "-in", str(path), "-pubkey", "-noout"], binary=True, quiet=True)
    der = run([openssl_bin, "pkey", "-pubin", "-outform", "DER"], input_bytes=pem, binary=True, quiet=True)
    return hashlib.sha256(der).hexdigest()


def pubkey_hash_from_cert(path):
    pem = run([openssl_bin, "x509", "-in", str(path), "-pubkey", "-noout"], binary=True, quiet=True)
    der = run([openssl_bin, "pkey", "-pubin", "-outform", "DER"], input_bytes=pem, binary=True, quiet=True)
    return hashlib.sha256(der).hexdigest()


created = 0
reused = 0
with hosts_csv.open(newline="") as f:
    reader = csv.DictReader(f)
    if not reader.fieldnames:
        raise SystemExit("[ERROR] hosts.csv has no header row")
    for row in reader:
        host_id = (row.get("host_id") or row.get("hostname") or row.get("host") or "").strip()
        if not host_id or host_id.startswith("#"):
            continue
        common_name = (row.get("common_name") or row.get("cn") or host_id).strip()
        csr = csr_dir / f"{host_id}-csr.pem"
        cert = cert_dir / f"{host_id}-cert.pem"
        ext = openssl_dir / f"{host_id}-cert-ext.cnf"
        if not csr.is_file():
            raise SystemExit(f"[ERROR] Missing CSR: {csr}")

        if cert.exists() and not overwrite:
            run([openssl_bin, "verify", "-CAfile", str(ca_cert), str(cert)], quiet=True)
            if pubkey_hash_from_csr(csr) != pubkey_hash_from_cert(cert):
                raise SystemExit(
                    f"[ERROR] Existing test certificate does not match CSR for {host_id}. "
                    "Set AUTO_TLS_OVERWRITE_ISSUED_CERTS=true to replace test-issued files."
                )
            print(f"[PASS] Reusing existing test-issued certificate for {host_id}: {cert}")
            reused += 1
            continue

        if cert.exists():
            print(f"[WARN] Replacing test-issued certificate for {host_id}")
            cert.unlink()

        dns_sans = split_list(row.get("dns_sans"))
        ip_sans = split_list(row.get("ip_sans"))
        try:
            normalized_host_ip = str(ipaddress.ip_address(host_id))
            if normalized_host_ip not in ip_sans:
                ip_sans.append(normalized_host_ip)
        except ValueError:
            if host_id not in dns_sans:
                dns_sans.append(host_id)
        try:
            normalized_cn_ip = str(ipaddress.ip_address(common_name))
            if normalized_cn_ip not in ip_sans:
                ip_sans.append(normalized_cn_ip)
        except ValueError:
            if common_name and common_name not in dns_sans:
                dns_sans.append(common_name)

        entries = [f"DNS:{x}" for x in dns_sans] + [f"IP:{str(ipaddress.ip_address(x))}" for x in ip_sans]
        if not entries:
            raise SystemExit(f"[ERROR] No SAN values for {host_id}")
        ext.write_text(
            "basicConstraints = " + os.environ["AUTO_TLS_HOST_BASIC_CONSTRAINTS"] + "\n"
            "subjectKeyIdentifier = hash\n"
            "authorityKeyIdentifier = keyid,issuer\n"
            "subjectAltName = " + ",".join(entries) + "\n"
            "keyUsage = " + os.environ["AUTO_TLS_KEY_USAGE"] + "\n"
            "extendedKeyUsage = " + os.environ["AUTO_TLS_EXTENDED_KEY_USAGE"] + "\n"
        )
        ext.chmod(0o640)

        cmd = [
            openssl_bin, "x509", "-req",
            "-in", str(csr),
            "-CA", str(ca_cert),
            "-CAkey", str(ca_key),
            "-passin", f"file:{ca_password_file}",
            "-CAserial", str(ca_serial),
            "-CAcreateserial",
            "-out", str(cert),
            "-days", os.environ["AUTO_TLS_CERT_DAYS"],
            f"-{os.environ['AUTO_TLS_DIGEST']}",
            "-extfile", str(ext),
        ]
        run(cmd)
        cert.chmod(0o644)
        run([openssl_bin, "verify", "-CAfile", str(ca_cert), str(cert)])
        if pubkey_hash_from_csr(csr) != pubkey_hash_from_cert(cert):
            raise SystemExit(f"[ERROR] Test-issued certificate does not match CSR for {host_id}")
        print(f"[OK] Test CA signed CSR for {host_id}: {cert}")
        created += 1

if created + reused < 1:
    raise SystemExit("[ERROR] No CSRs were signed or reused")
print(f"[OK] Test-issued certificates ready: created={created}, reused={reused}")
PY

apply_owner_if_available

echo "[OK] Simulated customer return files are in ${AUTO_TLS_CERT_DIR}"
echo "[INFO] The downstream validation and store-building steps are identical for customer and test certificates."
