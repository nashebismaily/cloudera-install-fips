#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_var AUTO_TLS_HOSTS_CSV
ensure_hosts_csv
require_cmd "${OPENSSL_BIN}"
prepare_dirs

"${SYSTEM_PYTHON_BIN}" - <<'PY'
import csv
import hashlib
import ipaddress
import os
import subprocess
import tarfile
from pathlib import Path

hosts_csv = Path(os.environ["AUTO_TLS_HOSTS_CSV"])
csr_dir = Path(os.environ["AUTO_TLS_CSR_DIR"])
manifest_file = Path(os.environ["AUTO_TLS_CSR_MANIFEST_FILE"])
instructions_file = Path(os.environ["AUTO_TLS_CSR_INSTRUCTIONS_FILE"])
checksum_file = Path(os.environ["AUTO_TLS_CSR_CHECKSUM_FILE"])
package_file = Path(os.environ["AUTO_TLS_CSR_PACKAGE_FILE"])
openssl_bin = os.environ["OPENSSL_BIN"]


def split_list(value):
    if not value:
        return []
    result = []
    for item in value.replace(",", ";").split(";"):
        item = item.strip()
        if item and item not in result:
            result.append(item)
    return result


def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_csr(path):
    result = subprocess.run(
        [openssl_bin, "req", "-in", str(path), "-verify", "-noout"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )
    if result.returncode:
        raise SystemExit(f"[ERROR] Invalid CSR {path}:\n{result.stderr}")


rows = []
csr_files = []
with hosts_csv.open(newline="") as f:
    reader = csv.DictReader(f)
    if not reader.fieldnames:
        raise SystemExit("[ERROR] hosts.csv has no header row")
    for row in reader:
        host_id = (row.get("host_id") or row.get("hostname") or row.get("host") or "").strip()
        if not host_id or host_id.startswith("#"):
            continue
        csr_file = csr_dir / f"{host_id}-csr.pem"
        if not csr_file.is_file() or csr_file.stat().st_size == 0:
            raise SystemExit(f"[ERROR] Missing CSR for {host_id}: {csr_file}")
        verify_csr(csr_file)

        common_name = (row.get("common_name") or row.get("cn") or host_id).strip()
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

        rows.append({
            "host_id": host_id,
            "common_name": common_name,
            "csr_file": csr_file.name,
            "returned_certificate_file": f"{host_id}-cert.pem",
            "dns_sans": ";".join(dns_sans),
            "ip_sans": ";".join(ip_sans),
            "csr_sha256": sha256(csr_file),
        })
        csr_files.append(csr_file)

if not rows:
    raise SystemExit("[ERROR] No CSRs found to package")

manifest_file.parent.mkdir(parents=True, exist_ok=True)
with manifest_file.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)

instructions = f"""CFM AUTO-TLS CERTIFICATE REQUEST PACKAGE

This package contains public certificate signing requests only. It does not
contain private keys, private-key passwords, keystore passwords, or truststore
passwords.

Signing requirements:
1. Sign every *-csr.pem file using the enterprise CA.
2. Preserve every DNS and IP Subject Alternative Name listed in the CSR and in
   certificate-request-manifest.csv.
3. Issue end-entity certificates with Basic Constraints CA:FALSE.
4. Include Key Usage: {os.environ['AUTO_TLS_KEY_USAGE']}.
5. Include Extended Key Usage: {os.environ['AUTO_TLS_EXTENDED_KEY_USAGE']}.
6. Return every leaf certificate in PEM format with this exact filename:
       <host_id>-cert.pem
7. Return the issuing CA chain in PEM format with this exact filename:
       ca-chain.pem
   Put the issuing intermediate first, then any higher intermediates, and the
   root CA last. Do not include a leaf certificate or private key in this file.
8. Do not generate replacement private keys. Each returned certificate must
   match the public key in its submitted CSR.
9. Return one unique certificate per host. Do not replace host-specific names
   with a wildcard certificate.

Files to return to the Cloudera administrator:
"""
for row in rows:
    instructions += f"  - {row['returned_certificate_file']}\n"
instructions += "  - ca-chain.pem\n\n"
instructions += f"The administrator will place the returned files in:\n  {os.environ['AUTO_TLS_CERT_DIR']}\n"
instructions_file.write_text(instructions)

checksum_lines = []
for path in sorted(csr_files + [manifest_file, instructions_file], key=lambda p: p.name):
    checksum_lines.append(f"{sha256(path)}  {path.name}")
checksum_file.write_text("\n".join(checksum_lines) + "\n")

for path in [manifest_file, instructions_file, checksum_file, *csr_files]:
    path.chmod(0o644)

package_file.parent.mkdir(parents=True, exist_ok=True)

if package_file.exists():
    package_file.unlink()
with tarfile.open(package_file, "w:gz") as tf:
    for path in sorted(csr_files + [manifest_file, instructions_file, checksum_file], key=lambda p: p.name):
        tf.add(path, arcname=f"customer-csr-package/{path.name}", recursive=False)
package_file.chmod(0o640)

with tarfile.open(package_file, "r:gz") as tf:
    names = tf.getnames()
    forbidden = [
        name for name in names
        if "key.pem" in name.lower()
        or "password" in name.lower()
        or name.lower().endswith(".pass")
        or "private" in name.lower()
    ]
    if forbidden:
        raise SystemExit(f"[ERROR] CSR package unexpectedly contains sensitive files: {forbidden}")

print(f"[OK] Wrote CSR manifest: {manifest_file}")
print(f"[OK] Wrote customer instructions: {instructions_file}")
print(f"[OK] Wrote checksums: {checksum_file}")
print(f"[OK] Created customer CSR package: {package_file}")
print("[INFO] Package contents:")
for name in names:
    print(f"  {name}")
PY

apply_owner_if_available

echo "[OK] Customer CSR handoff package is ready"
echo "[INFO] Send only this package to the customer's certificate authority team:"
echo "       ${AUTO_TLS_CSR_PACKAGE_FILE}"
echo "[INFO] Never send files from ${AUTO_TLS_KEY_DIR} or ${AUTO_TLS_PASSWORD_DIR}"
