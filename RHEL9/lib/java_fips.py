#!/usr/bin/env python3
"""Idempotently configure both upstream JDKs for the same approved provider set."""
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import shutil
import sys


def replace_block(text, label, block):
    begin = '# BEGIN MANAGED RHEL9 ' + label
    end = '# END MANAGED RHEL9 ' + label
    text = re.sub(re.escape(begin) + r'.*?' + re.escape(end) + r'\n?', '', text, flags=re.S)
    return text.rstrip() + '\n\n' + begin + '\n' + block.rstrip() + '\n' + end + '\n'


def write_changed(path, text):
    if path.read_text() == text:
        return
    stamp = datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S_%f')
    shutil.copy2(path, str(path) + '.bak.' + stamp)
    path.write_text(text)


def configure(home, env):
    security = Path(home) / env['JAVA_SECURITY_RELATIVE_PATH']
    policy = Path(home) / env['JAVA_POLICY_RELATIVE_PATH']
    if not security.is_file() or not policy.is_file():
        raise ValueError('Incomplete upstream JDK security configuration: ' + str(home))
    providers = [env['JAVA_FIPS_CCJ_PROVIDER_CLASS'],
                 env['JAVA_FIPS_BCTLS_PROVIDER_CLASS'] + ' ' + env['JAVA_FIPS_BCTLS_PROVIDER_ARGUMENT'],
                 env['JAVA_FIPS_SASL_PROVIDER_CLASS'], *env['JAVA_FIPS_STANDARD_PROVIDERS'].split()]
    old = security.read_text()
    # Remove the old managed block before commenting conflicting active entries.
    old = re.sub(r'# BEGIN MANAGED RHEL9 providers.*?# END MANAGED RHEL9 providers\n?', '', old, flags=re.S)
    prefixes = ('security.provider.', 'fips.provider.', 'ssl.KeyManagerFactory.algorithm=',
                'ssl.TrustManagerFactory.algorithm=', 'security.useSystemPropertiesFile=',
                'keystore.type=', 'com.safelogic.cryptocomply.fips.approved_only=',
                'org.bouncycastle.fips.approved_only=')
    lines = ['# ' + line if line.strip().startswith(prefixes) else line for line in old.splitlines()]
    block = ['security.useSystemPropertiesFile=false', 'keystore.type=BCFKS',
             'com.safelogic.cryptocomply.fips.approved_only=true', 'org.bouncycastle.fips.approved_only=true']
    for prefix in ('security.provider', 'fips.provider'):
        block.extend(f'{prefix}.{i}={value}' for i, value in enumerate(providers, 1))
    block += ['ssl.KeyManagerFactory.algorithm=' + env['JAVA_FIPS_KEY_MANAGER_ALGORITHM'],
              'ssl.TrustManagerFactory.algorithm=' + env['JAVA_FIPS_TRUST_MANAGER_ALGORITHM']]
    write_changed(security, replace_block('\n'.join(lines), 'providers', '\n'.join(block)))
    # Grant privileges only to the approved provider libraries, not application code.
    jars = [env[n] for n in ('FIPS_CCJ_JAR', 'FIPS_BCTLS_JAR', 'FIPS_BCUTIL_JAR', 'FIPS_SASL_JAR')]
    grants = '\n'.join('grant codeBase "file:' + str(Path(env['JAVA_FIPS_DIR']) / jar) +
                       '" { permission java.security.AllPermission; };' for jar in jars)
    old_policy = policy.read_text()
    begin, end = '// BEGIN MANAGED RHEL9 policy', '// END MANAGED RHEL9 policy'
    old_policy = re.sub(re.escape(begin) + r'.*?' + re.escape(end) + r'\n?', '', old_policy, flags=re.S)
    write_changed(policy, old_policy.rstrip() + '\n\n' + begin + '\n' + grants + '\n' + end + '\n')
    print('[OK] Configured JDK providers and policy: ' + str(home))


if __name__ == '__main__':
    try:
        for java_home in sys.argv[1:]:
            configure(java_home, os.environ)
    except (OSError, ValueError) as error:
        raise SystemExit('[ERROR] ' + str(error))
