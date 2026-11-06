"""Exercise archive/entitlement/host failures without touching real host configuration."""
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tarfile
import tempfile
import unittest
from urllib.error import HTTPError
import zipfile

from test_profile import ROOT, config
sys.path.insert(0, str(ROOT / 'lib'))
import fips_artifacts as fips
import prepare_artifacts as artifacts


def jar_bytes(entries):
    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w') as jar:
        for name in entries:
            jar.writestr(name, b'{"name":"NIFI","parameters":[]}' if name=='descriptor/service.sdl' else b'offline fixture')
    return out.getvalue()


class Host:
    def __init__(self, root):
        self.root = Path(root)
        self.kit_root = ROOT
        self.env = config()
        self.env.update({
            'FIPS_JAR_SOURCE_DIR': str(self.root / 'approved'),
            'FIPS_CHECKSUM_FILE': str(self.root / 'approved/SHA256SUMS'),
            'FIPS_BUNDLE_ARCHIVE': '',
            'ARTIFACT_STATE_DIR': str(self.root / 'state'),
            'ARTIFACT_LOCK_FILE': str(self.root / 'state/artifacts.json'),
            'ARTIFACT_CACHE_DIR': str(self.root / 'state/downloads'),
            'PARCEL_JAR_BACKUP_DIR': str(self.root / 'state/parcel-backups'),
            'CSD_BACKUP_DIR': str(self.root / 'state/csd-backups'),
            'CLOUDERA_INSTALL_ROOT': str(self.root / 'cloudera'),
            'CLOUDERA_PARCELS_DIR': str(self.root / 'parcels'),
            'CLOUDERA_REPO_USER': 'fixture', 'CLOUDERA_REPO_PASS': 'fixture',
            'BOOTSTRAP_PYTHON_BIN': sys.executable, 'SYSTEM_PYTHON_BIN': sys.executable,
            'LOG_DIR': str(self.root / 'logs'),
            'CFM_PARCEL_STATE_LINK': str(self.root / 'parcels/CFM'),
            'CDP_PARCEL_ROOT': str(self.root / 'parcels/CDH'),
            'CDP_SASL_DESTINATIONS': str(self.root / 'parcels/CDH/jars') + ' ' + str(self.root / 'parcels/CDH/lib/hadoop'),
        })
        self.source = Path(self.env['FIPS_JAR_SOURCE_DIR']); self.source.mkdir()
        self.names = [self.env[key] for key in ('FIPS_CCJ_JAR', 'FIPS_BCTLS_JAR', 'FIPS_BCUTIL_JAR')]
        self.names += self.env['FIPS_EXTRA_JARS'].split()
        for i, name in enumerate(self.names):
            content = jar_bytes([fips.CORE_CLASSES.get(name, 'fixture.class')])
            (self.source / name).write_bytes(content)
            digest = hashlib.sha256(content).hexdigest()
            formats = [digest + '\n', digest + '  ' + name + '\n', 'SHA256 (' + name + ') = ' + digest + '\n',
                       'SHA2-256(/vendor/staging/' + name + ')= ' + digest + '\n']
            (self.source / (name + '.sha256')).write_text(formats[i % len(formats)])
        self.sasl_name = 'sasl-sha256aes-0.1.0.' + self.env['CDP_RUNTIME_VERSION'] + '-17.jar'
        self.sasl = jar_bytes([fips.SASL_CLASS])
        self.cfm_name = 'CFM-' + self.env['CFM_VERSION'] + '-243-el9.parcel'
        self.cdp_name = 'CDH-7.3.2-1.cdh7.3.2.p1000.fixture-el9.parcel'
        self.replies = {
            self.env['CM_REPO_METADATA_URL']: b'<?xml version="1.0"?><repomd/>',
            self.env['CFM_MANIFEST_URL']: json.dumps({'parcels': [
                {'parcelName': self.cfm_name.replace('-el9.', '-el8.'), 'hash': 'c' * 40},
                {'parcelName': self.cfm_name, 'hash': 'a' * 40}]}).encode(),
            self.env['CDP_PARCEL_REPO_URL'] + 'manifest.json': json.dumps({'parcels': [
                {'parcelName': self.cdp_name, 'hash': 'b' * 40}]}).encode(),
            self.env['FIPS_SASL_REPOSITORY_URL']: ('<a href="0.1.0.' + self.env['CDP_RUNTIME_VERSION'] + '-17/">SASL</a>').encode(),
        }
        self.sasl_url = self.env['FIPS_SASL_REPOSITORY_URL'] + '0.1.0.' + self.env['CDP_RUNTIME_VERSION'] + '-17/' + self.sasl_name
        self.replies[self.sasl_url] = self.sasl
        self.replies[self.sasl_url + '.sha256'] = hashlib.sha256(self.sasl).hexdigest().encode()
        for service in ('NIFI', 'NIFIREGISTRY'):
            name = service + '-2.6.0.' + self.env['CFM_VERSION'] + '-243.jar'
            self.replies[self.env['CFM_CSD_BASE_URL'] + name] = jar_bytes(['descriptor/service.sdl'])
        self.calls = []
        self.binaries = self.root / 'bin'; self.binaries.mkdir()
        self.fake_binary('rpm', 'printf "9\\n"')
        self.fake_binary('policy', 'printf "FIPS\\n"')
        self.fake_binary('fips-mode-setup', 'exit 0')
        (self.root / 'os-release').write_text('ID=rhel\nVERSION_ID=9.8\n')
        (self.root / 'fips').write_text('1\n')
        self.env.update(OS_RELEASE_FILE=str(self.root / 'os-release'),
                        FIPS_KERNEL_FLAG_FILE=str(self.root / 'fips'),
                        CRYPTO_POLICY_COMMAND=str(self.binaries / 'policy'))

    def get(self, url, limit=0):
        self.calls.append(url)
        if url not in self.replies:
            raise HTTPError(url, 404, 'offline fixture', None, None)
        return self.replies[url]

    def fake_binary(self, name, body):
        p = self.binaries / name; p.write_text('#!/usr/bin/env bash\n' + body + '\n'); p.chmod(0o755)

    def run(self, script, *args):
        site = self.root / 'EXPORTS'
        names = set(config())
        site.write_text('source ' + shlex.quote(str(self.kit_root / 'EXPORTS')) + '\n' +
                        ''.join('export ' + key + '=' + shlex.quote(str(value)) + '\n' for key, value in self.env.items()
                                if key in names or key.startswith(('CDP_PARCEL', 'CFM_PARCEL', 'PG_', 'POSTGRES_'))))
        env = dict(os.environ, EXPORTS_FILE=str(site), PATH=str(self.binaries) + os.pathsep + os.environ['PATH'])
        return subprocess.run(['bash', str(self.kit_root / script), *args], env=env, capture_output=True, text=True, timeout=60)


class Rhel98Tests(unittest.TestCase):
    def test_requested_os_controls_and_untouched_system_python(self):
        env = config()
        self.assertEqual(env['DISABLE_FIREWALLD'], 'true')
        self.assertEqual(env['FAPOLICYD_MODE'], 'disable')
        self.assertEqual(env['BOOTSTRAP_PYTHON_BIN'], '/usr/bin/python3')
        self.assertEqual(env['CM_AGENT_PYTHON_BIN'], '/usr/bin/python3.11')
        self.assertEqual(len(env['FIPS_EXTRA_JARS'].split()), 4)
        agent = (ROOT / '10_configure_cm_agent.sh').read_text()
        self.assertNotIn('ln -sf', agent)
        self.assertNotIn('psycopg2-binary', agent)

    def test_actual_bundle_sidecars_and_safe_extraction(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = Host(tmp)
            archive = Path(tmp) / 'vendor.tar.gz'
            with tarfile.open(archive, 'w:gz') as tf:
                for p in host.source.iterdir():
                    tf.add(p, arcname='Cloudera-SP1/' + p.name)
            dest = Path(tmp) / 'unpacked'
            fips.unpack_bundle(archive, dest, host.names)
            self.assertEqual(len(list(dest.glob('*.jar'))), 7)
            fips.validate_bundle(dest, host.names)
            (dest / host.names[0]).write_bytes(b'previous input')
            with self.assertRaisesRegex(ValueError, 'Different artifact'):
                fips.unpack_bundle(archive, dest, host.names)
            self.assertEqual((dest / host.names[0]).read_bytes(), b'previous input')
            for unsafe in ('../../escape', '/absolute', 'linked.jar'):
                with tarfile.open(archive, 'w:gz') as tf:
                    info = tarfile.TarInfo(unsafe)
                    if unsafe == 'linked.jar': info.type = tarfile.SYMTYPE; info.linkname = '/etc/passwd'
                    tf.addfile(info, io.BytesIO())
                with self.assertRaisesRegex(ValueError, 'Unsafe'):
                    fips.unpack_bundle(archive, dest, host.names)

    def test_manifest_filtering_and_build_ambiguity(self):
        env = config()
        good = {'parcelName': 'CFM-4.12.0.10001-243-el9.parcel', 'hash': 'a' * 40}
        wrong_os = dict(good, parcelName=good['parcelName'].replace('el9', 'el8'))
        self.assertEqual(artifacts.select_parcel({'parcels': [wrong_os, good]}, env, 'CFM'),
                         {'name': good['parcelName'], 'hash': 'a' * 40})
        second = dict(good, parcelName=good['parcelName'].replace('-243-', '-244-'))
        with self.assertRaisesRegex(ValueError, 'Expected one'):
            artifacts.select_parcel({'parcels': [good, second]}, env, 'CFM')
        env['CFM_BUILD'] = '244'
        self.assertEqual(artifacts.select_parcel({'parcels': [good, second]}, env, 'CFM')['name'], second['parcelName'])
        with self.assertRaisesRegex(ValueError, 'hash'):
            artifacts.select_parcel({'parcels': [dict(second, hash='wrong')]}, env, 'CFM')

    def test_entire_artifact_resolution_locks_matching_csds_and_rejects_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = Host(tmp)
            artifacts.prepare(host.env, host)
            lock = json.loads(Path(host.env['ARTIFACT_LOCK_FILE']).read_text())
            self.assertEqual(lock['cfm']['build'], '243')
            self.assertTrue(all('-243.jar' in name for name in lock['csds']))
            self.assertEqual(len(lock['bundle_sha256']), 7)
            self.assertIn('archive SHA256', lock['sasl']['provenance'])
            values = artifacts.shell_exports(host.env)
            self.assertIn('CFM_BUILD=243', values)
            self.assertIn(host.cdp_name[:-len('-el9.parcel')], values)
            artifacts.prepare(host.env, host)
            self.assertEqual(json.loads(Path(host.env['ARTIFACT_LOCK_FILE']).read_text())['sasl'], lock['sasl'])
            name = next(iter(lock['csds']))
            host.replies[host.env['CFM_CSD_BASE_URL'] + name] = jar_bytes(['descriptor/service.sdl', 'changed'])
            with self.assertRaisesRegex(ValueError, 'CSD changed'):
                artifacts.prepare(host.env, host)
            self.assertEqual(json.loads(Path(host.env['ARTIFACT_LOCK_FILE']).read_text())['csds'], lock['csds'])

    def test_sasl_without_published_sha256_reports_transport_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = Host(tmp); del host.replies[host.sasl_url + '.sha256']
            sasl = artifacts.stage_sasl(host.env, host)
            self.assertIn('recorded locally', sasl['provenance'])
            self.assertNotIn('archive SHA256', sasl['provenance'])
            self.assertEqual(sasl['sha256'], hashlib.sha256(host.sasl).hexdigest())
            (host.source / host.sasl_name).write_bytes(b'tamper')
            with self.assertRaisesRegex(ValueError, 'SHA256'):
                artifacts.stage_sasl(host.env, host)

    @unittest.skipUnless(os.geteuid() == 0, 'Runs real root-gated host scripts inside a fake host')
    def test_cdp_sasl_before_cfm_and_full_library_distribution(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = Host(tmp); artifacts.prepare(host.env, host)
            parcels = host.root / 'parcels'; parcels.mkdir()
            cdp = parcels / host.cdp_name[:-len('-el9.parcel')]
            for p in (cdp / 'jars', cdp / 'lib/hadoop'): p.mkdir(parents=True)
            (parcels / 'CDH').symlink_to(cdp, target_is_directory=True)
            result = host.run('14_install_cfm_fips_jars.sh', 'cdp')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((cdp / 'jars' / host.sasl_name).read_bytes(), host.sasl)
            result = host.run('14_install_cfm_fips_jars.sh')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Activate', result.stdout)
            cfm = parcels / host.cfm_name[:-len('-el9.parcel')]
            for part in ('TOOLKIT', 'REGISTRY', 'NIFI'): (cfm / part / 'lib').mkdir(parents=True)
            old = cfm / 'NIFI/lib/ccj-3.0.2.1.jar'; old.write_text('old provider fixture')
            (parcels / 'CFM').symlink_to(cfm, target_is_directory=True)
            result = host.run('14_install_cfm_fips_jars.sh')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for part in ('TOOLKIT', 'REGISTRY', 'NIFI'):
                for name in host.names[:3]:
                    self.assertEqual((cfm / part / 'lib' / name).read_bytes(), (host.source / name).read_bytes())
            self.assertFalse(old.exists())
            self.assertTrue(list((host.root / 'state/parcel-backups').rglob(old.name)))
            self.assertEqual((cfm / 'NIFI/lib' / host.sasl_name).read_bytes(), host.sasl)
            self.assertFalse((cfm / 'NIFI/lib/bcpqc-8.5.jar').exists())

    @unittest.skipUnless(os.geteuid() == 0, 'Runs real root-gated CSD install against a fake CM host')
    def test_csd_install_preserves_other_services_and_validates_before_replacing(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = Host(tmp); artifacts.prepare(host.env, host)
            csds = host.root / 'csd'; csds.mkdir()
            (csds / 'KAFKA-fixture.jar').write_bytes(b'keep')
            (csds / 'NIFI-old.jar').write_bytes(b'old')
            host.env.update(CFM_CSD_DIR=str(csds), CLOUDERA_SERVICE_USER='root', CLOUDERA_SERVICE_GROUP='root')
            host.fake_binary('systemctl', 'exit 1')
            result = host.run('13_install_cfm_csds.sh')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((csds / 'KAFKA-fixture.jar').read_bytes(), b'keep')
            self.assertFalse((csds / 'NIFI-old.jar').exists())
            lock = artifacts.load_lock(host.env); name = next(iter(lock['csds']))
            before = (csds / name).read_bytes()
            (Path(host.env['ARTIFACT_CACHE_DIR']) / name).write_bytes(b'tampered')
            result = host.run('13_install_cfm_csds.sh')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('checksum mismatch', result.stdout + result.stderr)
            self.assertEqual((csds / name).read_bytes(), before)

    @unittest.skipUnless(os.geteuid() == 0, 'Uses fake systemd/sysctl and isolated configuration paths')
    def test_os_prerequisites_disable_and_mask_both_blocking_services(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = Host(tmp); trace = host.root / 'calls'
            host.fake_binary('systemctl', 'printf "%s\\n" "$*" >> ' + shlex.quote(str(trace)) + '\n'
                             'if [[ "$1" == list-unit-files ]]; then printf "%s enabled\\n" "$4"; fi\nexit 0')
            host.fake_binary('setenforce', 'exit 0')
            host.fake_binary('getenforce', 'echo Permissive')
            host.fake_binary('sysctl', 'exit 0')
            (host.root / 'selinux').write_text('SELINUX=enforcing\n')
            (host.root / 'thp').write_text('always madvise [never]\n')
            host.env.update(SELINUX_CONFIG_FILE=str(host.root / 'selinux'), THP_SERVICE_FILE=str(host.root / 'thp.service'),
                            THP_ENABLED_FILE=str(host.root / 'thp'), THP_DEFRAG_FILE=str(host.root / 'thp'),
                            CLOUDERA_SYSCTL_FILE=str(host.root / 'sysctl.conf'),
                            CLOUDERA_SYSTEMD_LIMITS_DIR=str(host.root / 'systemd'),
                            CLOUDERA_SYSTEMD_LIMITS_FILE=str(host.root / 'systemd/limits.conf'),
                            CLOUDERA_SECURITY_LIMITS_DIR=str(host.root / 'security'),
                            CLOUDERA_SECURITY_LIMITS_FILE=str(host.root / 'security/limits.conf'))
            result = host.run('03_configure_os.sh')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            commands = trace.read_text()
            for service in ('firewalld', 'fapolicyd'):
                for action in ('stop', 'disable', 'mask'):
                    self.assertIn(action + ' ' + service + '\n', commands)
            self.assertEqual((host.root / 'selinux').read_text(), 'SELINUX=disabled\n')
            self.assertIn('vm.swappiness=1', (host.root / 'sysctl.conf').read_text())

    def test_artifact_redirect_never_leaks_credentials_to_another_origin(self):
        from urllib.request import Request
        handler = artifacts.SameOriginRedirect()
        request = Request('https://archive.cloudera.com/p/artifact', headers={'Authorization': 'Basic fixture'})
        for target in ('http://archive.cloudera.com/p/other', 'https://other.example/file'):
            with self.assertRaisesRegex(ValueError, 'redirect'):
                handler.redirect_request(request, None, 302, 'redirect', {}, target)

    @unittest.skipUnless(os.geteuid() == 0, 'Runs isolated host scripts with mocked package commands')
    def test_cm_package_pins_and_jdbc_driver_link(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = Host(tmp); artifacts.prepare(host.env, host)
            jdk = host.root / 'jdk/bin'; jdk.mkdir(parents=True)
            for name in ('java', 'jar', 'keytool'):
                p = jdk / name; p.write_text('#!/bin/sh\necho \'openjdk version "17.0.13"\' >&2\n'); p.chmod(0o755)
            trace = host.root / 'dnf-calls'
            driver = host.root / 'jdbc/postgresql-jdbc.jar'; driver.parent.mkdir()
            driver.write_bytes(jar_bytes(['org/postgresql/Driver.class']))
            host.fake_binary('dnf', 'printf "%s\\n" "$*" >> ' + shlex.quote(str(trace)))
            host.fake_binary('rpm', 'case "$1" in\n-E) echo 9;;\n-q) echo 7.13.2.10000;;\n-ql) echo ' + shlex.quote(str(driver)) + ';;\n-qa) echo cloudera-manager-server;;\nesac')
            host.env.update(JAVA_HOME_TARGET=str(jdk.parent), CM_AGENT_PYTHON_WRAPPER=sys.executable,
                            INSTALL_HUE_FIPS_PSYCOPG2='false', CM_AGENT_PYTHON_BIN=sys.executable,
                            CM_AGENT_PYTHON_EXPECTED_VERSION='Python ' + str(sys.version_info.major) + '.' + str(sys.version_info.minor),
                            POSTGRES_JDBC_DIR=str(driver.parent), POSTGRES_JDBC_LINK=str(driver.parent / 'postgresql-connector-java.jar'))
            result = host.run('09_install_cm_packages.sh', 'manager')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for package in ('daemons', 'agent', 'server'):
                self.assertIn('cloudera-manager-' + package + '-7.13.2.10000', trace.read_text())
            self.assertEqual(Path(host.env['POSTGRES_JDBC_LINK']).resolve(), driver)
            host.fake_binary('rpm', 'if [[ "$1" == -E ]]; then echo 9; else echo 7.13.2.20000; fi')
            result = host.run('09_install_cm_packages.sh', 'manager')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Wrong CM RPM version', result.stdout)

    @unittest.skipUnless(os.geteuid() == 0, 'Runs isolated PostgreSQL configuration')
    def test_postgresql_non_ssl_scram_rule_precedence_and_idempotency(self):
        with tempfile.TemporaryDirectory() as tmp:
            host=Host(tmp);data=host.root/'pgdata';data.mkdir()
            (data/'postgresql.conf').write_text("listen_addresses = 'localhost'\npassword_encryption = 'md5'\nssl = 'on'\n")
            (data/'pg_hba.conf').write_text('local all all peer\nhost all all 127.0.0.1/32 trust\n')
            pg_bin=host.root/'pg-bin';pg_bin.mkdir()
            (pg_bin/'psql').write_text('#!/bin/sh\necho "off scram-sha-256"\n');(pg_bin/'psql').chmod(0o755)
            host.fake_binary('systemctl','exit 0');host.fake_binary('runuser','shift 3\nexec "$@"')
            host.env.update(PGDATA_DIR=str(data),PG_OS_USER='root',PG_OS_GROUP='root',PGDATA_OWNER='root:root',
                            PG_BIN_DIR=str(pg_bin),DB_HOST='cm.fixture.test')
            for _ in range(2):
                result=host.run('06_configure_postgres_networking.sh')
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            hba=(data/'pg_hba.conf').read_text();settings=(data/'postgresql.conf').read_text()
            self.assertEqual(hba.count(host.env['PG_HBA_MANAGED_BEGIN']),1)
            self.assertLess(hba.index('host all all 127.0.0.1/32 scram-sha-256'),hba.index('host all all 127.0.0.1/32 trust'))
            self.assertIn('host all all ::1/128 scram-sha-256',hba)
            self.assertIn('host all all 0.0.0.0/0 reject',hba)
            self.assertNotIn('hostssl',hba);self.assertNotIn('hostnossl',hba)
            self.assertEqual(settings.count('# BEGIN MANAGED RHEL9 PostgreSQL'),1)
            self.assertIn("ssl = 'off'",settings)
            self.assertNotIn('ssl_cert_file',settings)


if __name__ == '__main__':
    unittest.main()
