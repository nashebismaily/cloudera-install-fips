#!/usr/bin/env python3
"""Use real node certificate DNs, avoiding an invented OU suffix or identity mapping."""
import csv
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess


def template(identities):
    templates = set()
    for host, dn in identities.items():
        match = re.search(r'(?:^|,)CN=' + re.escape(host) + r'(?=,|$)', dn)
        if not match:
            raise ValueError('Node certificate CN must match its CM host identity: ' + host)
        offset = match.end() - len(host)
        templates.add((dn[:offset], dn[match.end():]))
    if len(templates) != 1:
        raise ValueError('Node certificates do not share one DN prefix/suffix template; configure explicit full node identities in CM for this certificate policy')
    return templates.pop()


def derive(env):
    certificates = {}
    inventory = Path(env['AUTO_TLS_HOSTS_CSV'])
    if inventory.is_file():
        with inventory.open(newline='') as handle:
            for row in csv.DictReader(handle):
                host = row.get('host_id', '').strip()
                if not host or host.startswith('#'):
                    continue
                path = Path(env['AUTO_TLS_CERT_DIR']) / (host + '-cert.pem')
                if path.is_file():
                    certificates[host] = path
    local = Path(env['CM_AGENT_HOST_CERT_FILE'])
    if local.is_file():
        certificates[env.get('AGENT_HOST') or socket.getfqdn()] = local
    selected = set(env.get('NIFI_NODE_HOSTS', '').replace(',', ' ').split())
    if selected:
        missing = selected - set(certificates)
        if missing:
            raise ValueError('Stage the public returned node certificates for these NiFi hosts before generating configuration: ' + ', '.join(sorted(missing)))
        certificates = {host: path for host, path in certificates.items() if host in selected}
    if not certificates:
        raise ValueError('No real node certificates found; set CM_AGENT_HOST_CERT_FILE to the local Auto-TLS certificate chain')
    args = [str(Path(env['JAVA_HOME_TARGET']) / 'bin/java'), *shlex.split(env['AUTO_TLS_JAVA_OPTIONS']),
            str(Path(__file__).with_name('SubjectDN.java'))]
    for host, path in sorted(certificates.items()):
        args.extend([host, str(path)])
    child = dict(os.environ); child.pop('JDK_JAVA_OPTIONS', None)
    result = subprocess.run(args, env=child, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise ValueError('Could not inspect actual Java certificate DNs: ' + result.stderr[-800:])
    identities = dict(line.split('\t', 1) for line in result.stdout.splitlines())
    prefix, suffix = template(identities)
    if env['NIFI_NODE_DN_MODE'] == 'configured':
        if (env['NIFI_NODE_DN_PREFIX'], env['NIFI_NODE_DN_SUFFIX']) != (prefix, suffix):
            raise ValueError('Configured generated node DN prefix/suffix does not match the actual certificates')
    elif env['NIFI_NODE_DN_MODE'] != 'certificate':
        raise ValueError('NIFI_NODE_DN_MODE must be certificate or configured')
    output = Path(env['CFM_GENERATED_CONFIG_DIR']); output.mkdir(parents=True, exist_ok=True); output.chmod(0o700)
    (output / 'node-identities.json').write_text(json.dumps({'unmapped_certificate_dns': identities,
        'prefix': prefix, 'suffix': suffix}, indent=2) + '\n')
    (output / 'node-identities.json').chmod(0o600)
    print('export NIFI_NODE_DN_PREFIX=' + shlex.quote(prefix))
    print('export NIFI_NODE_DN_SUFFIX=' + shlex.quote(suffix))


if __name__ == '__main__':
    try:
        derive(os.environ)
    except (OSError, ValueError) as error:
        raise SystemExit('[ERROR] ' + str(error))
