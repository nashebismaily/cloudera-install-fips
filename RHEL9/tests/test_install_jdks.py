"""Fresh-host JDK installation, download failures, safe extraction and reruns."""
import hashlib
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest

from test_profile import config, module

jdks = module('install_jdks')


def archive_bytes(major):
    result = io.BytesIO()
    with tarfile.open(fileobj=result, mode='w:gz') as tf:
        files = {'release': 'JAVA_VERSION="' + str(major) + '.0.13"\nOS_ARCH="x86_64"\nIMPLEMENTOR="Eclipse Adoptium"\n',
                 'conf/security/java.security': 'security.provider.1=SUN\n',
                 'conf/security/java.policy': 'grant {};\n'}
        for name in ('java', 'javac', 'jar', 'keytool'):
            files['bin/' + name] = '#!/bin/sh\necho \'openjdk version "' + str(major) + '.0.13"\' >&2\n'
        for name, content in files.items():
            info = tarfile.TarInfo('jdk-' + str(major) + '/' + name)
            data = content.encode(); info.size = len(data)
            info.mode = 0o755 if name.startswith('bin/') else 0o644
            tf.addfile(info, io.BytesIO(data))
    return result.getvalue()


class Vendor:
    def __init__(self, env):
        self.replies = {}; self.calls = []; self.assets = {}
        for major in (17, 21):
            content = archive_bytes(major)
            name = 'OpenJDK' + str(major) + '.tar.gz'
            url = 'https://vendor.example/' + name
            # /assets/latest returns no release_type field, unlike the GA
            # feature-release endpoint. Match the real API response shape.
            item = {'release_name': 'jdk-' + str(major) + '.0.13+9', 'vendor': 'eclipse',
                    'version': {'major': major},
                    'binary': {'architecture': 'x64', 'os': 'linux', 'image_type': 'jdk',
                               'jvm_impl': 'hotspot', 'heap_size': 'normal',
                               'package': {'name': name, 'link': url,
                                           'checksum': hashlib.sha256(content).hexdigest()}}}
            self.replies[url] = content
            self.assets[major] = item
            self.replies[env['JAVA_DOWNLOAD_API_URL'] + '/' + str(major) + '/hotspot'] = json.dumps([item]).encode()

    def fetch(self, url, destination):
        self.calls.append(url)
        Path(destination).write_bytes(self.replies[url.split('?')[0]])


class JdkInstallTests(unittest.TestCase):
    def environment(self, root):
        env = config()
        env.update(JAVA_HOME_TARGET=str(root / 'jdk-17'), CFM_JAVA_HOME=str(root / 'jdk-21'),
                   JAVA_DOWNLOAD_CACHE_DIR=str(root / 'cache'))
        return env

    def test_both_jdks_are_automatically_installed_and_rerun_works_offline(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); env = self.environment(root); vendor = Vendor(env)
            previous_umask = os.umask(0o077)
            try:
                jdks.install(env, vendor)
            finally:
                os.umask(previous_umask)
            self.assertEqual(len(vendor.calls), 4)
            self.assertEqual(root.stat().st_mode & 0o777, 0o755, 'Service users must be able to traverse the Java parent')
            for major in (17, 21):
                home = root / ('jdk-' + str(major))
                self.assertEqual(jdks.validate_home(home, major), str(major) + '.0.13')
                manifest = json.loads((root / 'cache' / ('jdk-' + str(major) + '-installed.json')).read_text())
                self.assertEqual(manifest['sha256'], vendor.assets[major]['binary']['package']['checksum'])
                self.assertEqual(home.stat().st_mode & 0o777, 0o755)
            vendor.replies.clear()
            jdks.install(env, vendor)
            self.assertEqual(len(vendor.calls), 4, 'A rerun must reuse complete installed JDKs without network access')

    def test_wrong_download_checksum_stops_before_java_home_is_created(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); env = self.environment(root); vendor = Vendor(env)
            vendor.replies[vendor.assets[17]['binary']['package']['link']] = b'corrupt archive'
            with self.assertRaisesRegex(ValueError, 'SHA256'):
                jdks.install(env, vendor)
            self.assertFalse((root / 'jdk-17').exists())
            self.assertFalse(list((root / 'cache').glob('*.part')))

    def test_local_archives_are_verified_later_and_need_no_download(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); env = self.environment(root); vendor = Vendor(env)
            for major, prefix in ((17, 'JAVA'), (21, 'CFM_JAVA')):
                path = root / (str(major) + '.tar.gz'); path.write_bytes(archive_bytes(major))
                env[prefix + '_ARCHIVE_FILE'] = str(path)
                env[prefix + '_ARCHIVE_SHA256'] = hashlib.sha256(path.read_bytes()).hexdigest()
            env.update(ALLOW_EXTERNAL='false', JAVA_AUTO_DOWNLOAD='false')
            jdks.install(env, vendor)
            self.assertEqual(vendor.calls, [])
            env['JAVA_ARCHIVE_SHA256'] = '0' * 64
            with self.assertRaisesRegex(ValueError, 'SHA256'):
                jdks.install(env, vendor)

    def test_wrong_architecture_and_early_access_assets_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = self.environment(Path(tmp)); vendor = Vendor(env)
            asset = vendor.assets[17]
            asset['binary']['architecture'] = 'aarch64'
            with self.assertRaises(ValueError): jdks.select_asset([asset], 17, env)
            asset['binary']['architecture'] = 'x64'; asset['release_type'] = 'ea'
            with self.assertRaises(ValueError): jdks.select_asset([asset], 17, env)

    def test_archive_path_escape_and_symlink_writes_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); archive = root / 'unsafe.tar.gz'
            for members in [('jdk/../../escape',), ('jdk/link', 'jdk/link/file')]:
                with tarfile.open(archive, 'w:gz') as tf:
                    for name in members:
                        info = tarfile.TarInfo(name)
                        if name == 'jdk/link':
                            info.type = tarfile.SYMTYPE; info.linkname = 'bin'
                        tf.addfile(info, io.BytesIO())
                with self.assertRaises(ValueError):
                    jdks.extract_archive(archive, root / 'target', 17)
                self.assertFalse((root / 'target').exists())
                self.assertFalse((root / 'escape').exists())

    def test_downloads_cannot_redirect_to_http(self):
        from urllib.request import Request
        with self.assertRaisesRegex(ValueError, 'HTTPS'):
            jdks.HttpsOnly().redirect_request(Request('https://vendor.example/jdk'), None, 302, '', {}, 'http://vendor.example/jdk')


if __name__ == '__main__': unittest.main()
