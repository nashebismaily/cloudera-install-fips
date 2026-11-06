#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
source "${SCRIPT_DIR}/lib.sh"
ensure_hosts_csv
require_file "${AUTO_TLS_ISSUED_CA_CHAIN_FILE}"
require_cmd "${OPENSSL_BIN}"
require_file "${AUTO_TLS_JAVA_BIN}"
prepare_dirs
"${SYSTEM_PYTHON_BIN}" - <<'PY'
import csv, os, shlex, subprocess, tempfile
from pathlib import Path
root=Path(os.environ['SCRIPT_DIR'])
java=[os.environ['AUTO_TLS_JAVA_BIN'],*shlex.split(os.environ['AUTO_TLS_JAVA_OPTIONS'])]
type_=os.environ['AUTO_TLS_STORE_TYPE'];extension=type_.lower()
with open(os.environ['AUTO_TLS_HOSTS_CSV'],newline='') as handle:
    for row in csv.DictReader(handle):
        host=(row.get('host_id') or row.get('hostname') or row.get('host') or '').strip()
        if not host or host.startswith('#'): continue
        key=Path(os.environ['AUTO_TLS_KEY_DIR'])/f'{host}-key.pem'
        cert=Path(os.environ['AUTO_TLS_CERT_DIR'])/f'{host}-cert.pem'
        chain=Path(os.environ['AUTO_TLS_ISSUED_CA_CHAIN_FILE'])
        mode_check=subprocess.run([os.environ['OPENSSL_BIN'],'pkey','-in',str(key),'-passin','pass:','-check','-noout'],
                                  stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        encrypted=os.environ['AUTO_TLS_ENCRYPT_HOST_KEYS']=='true'
        if encrypted and mode_check.returncode==0:
            raise SystemExit('[ERROR] Unencrypted private key conflicts with encrypted-key mode: '+host)
        if not encrypted and mode_check.returncode!=0:
            raise SystemExit('[ERROR] Encrypted or unreadable key conflicts with unencrypted-key mode: '+host)
        # Decrypt only to process memory; no unencrypted private key or temporary PKCS12 is written.
        decrypt=[os.environ['OPENSSL_BIN'],'pkcs8','-topk8','-nocrypt','-outform','DER','-in',str(key)]
        if os.environ['AUTO_TLS_ENCRYPT_HOST_KEYS']=='true':
            decrypt += ['-passin','file:'+os.environ['AUTO_TLS_HOST_KEY_PASSWORD_FILE']]
        else: decrypt += ['-passin','pass:']
        result=subprocess.run(decrypt,stdout=subprocess.PIPE,stderr=subprocess.PIPE,stdin=subprocess.DEVNULL)
        if result.returncode: raise SystemExit('[ERROR] Cannot decode private key for '+host+': '+result.stderr.decode())
        with tempfile.TemporaryDirectory(dir=os.environ['AUTO_TLS_STORE_DIR']) as tmp:
            temp=Path(tmp);keystore=temp/'keystore';truststore=temp/'truststore'
            command=java+[str(root/'StoreTool.java'),'build',host,str(cert),str(chain),str(keystore),str(truststore)]
            subprocess.run(command,input=result.stdout,check=True)
            for kind,path in [('keystore',keystore),('truststore',truststore)]:
                path.chmod(0o600)
                path.replace(Path(os.environ['AUTO_TLS_STORE_DIR'])/f'{host}-{kind}.{extension}')
        print('[OK] Built '+type_+' stores for '+host)
PY
apply_owner_if_available
echo "[OK] ${AUTO_TLS_STORE_TYPE} keystores and truststores generated without PKCS12 intermediates."
