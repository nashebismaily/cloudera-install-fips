#!/usr/bin/env python3
"""Install complete upstream JDKs without requiring Java, jq, pip or Python 3.11."""
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import shutil
import ssl
import subprocess
import sys
import tarfile
import tempfile
import time
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener, HTTPSHandler


class HttpsOnly(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require_https(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def require_https(url):
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError('JDK download URLs must use verified HTTPS without embedded credentials')


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def atomic_json(path, value):
    path = Path(path)
    with tempfile.NamedTemporaryFile(mode='w', dir=str(path.parent), delete=False) as handle:
        temporary = Path(handle.name)
        json.dump(value, handle, indent=2)
        handle.write('\n')
    temporary.chmod(0o600)
    temporary.replace(path)


class Downloads:
    def __init__(self, env):
        self.timeout = int(env['JAVA_DOWNLOAD_TIMEOUT'])
        self.retries = int(env['JAVA_DOWNLOAD_RETRIES'])
        self.opener = build_opener(HttpsOnly(), HTTPSHandler(context=ssl.create_default_context()))

    def fetch(self, url, destination):
        require_https(url)
        for attempt in range(self.retries):
            try:
                request = Request(url, headers={'User-Agent': 'cloudera-fips-bootstrap'})
                with self.opener.open(request, timeout=self.timeout) as response, Path(destination).open('wb') as out:
                    require_https(response.geturl())
                    shutil.copyfileobj(response, out, length=1024 * 1024)
                return
            except Exception:
                Path(destination).unlink(missing_ok=True)
                if attempt + 1 == self.retries:
                    raise
                time.sleep(min(attempt + 1, 5))


def select_asset(items, major, env):
    matches = []
    for item in items:
        binary = item.get('binary', {})
        package = binary.get('package', {})
        if (item.get('release_type', 'ga') == 'ga'
                and not re.search(r'(^|[-+])ea([-.+]|$)', item.get('release_name', ''), re.I)
                and item.get('version', {}).get('major') == int(major)
                and item.get('vendor') == env['JAVA_DOWNLOAD_VENDOR']
                and all(binary.get(key) == expected for key, expected in {
                    'os': 'linux', 'architecture': env['JAVA_DOWNLOAD_ARCH'],
                    'image_type': 'jdk', 'jvm_impl': 'hotspot', 'heap_size': 'normal'}.items())):
            name = package.get('name', '')
            checksum = package.get('checksum', '')
            if not name or Path(name).name != name or not name.endswith('.tar.gz'):
                raise ValueError('Invalid upstream JDK package filename')
            if not re.fullmatch(r'[a-fA-F0-9]{64}', checksum):
                raise ValueError('Upstream JDK metadata has no valid SHA256')
            require_https(package.get('link', ''))
            matches.append({'release': item['release_name'], 'major': int(major),
                            'name': name, 'url': package['link'], 'sha256': checksum.lower(),
                            'architecture': binary['architecture'], 'vendor': item['vendor']})
    if len(matches) != 1:
        raise ValueError('Expected exactly one upstream Linux x64 GA JDK ' + str(major) + ' asset')
    return matches[0]


def validate_home(home, major):
    home = Path(home)
    for name in ('java', 'javac', 'jar', 'keytool'):
        if not os.access(str(home / 'bin' / name), os.X_OK):
            raise ValueError('Incomplete JDK ' + str(major) + ': missing executable ' + str(home / 'bin' / name))
    release = (home / 'release').read_text()
    version = re.search(r'^JAVA_VERSION="([^"]+)"', release, re.M)
    arch = re.search(r'^OS_ARCH="([^"]+)"', release, re.M)
    if not version or not version[1].startswith(str(major) + '.'):
        raise ValueError('JDK home contains the wrong Java major: ' + str(home))
    if not arch or arch[1] not in ('x86_64', 'amd64'):
        raise ValueError('JDK home is not Linux x86_64: ' + str(home))
    if re.search(r'^IMPLEMENTOR="[^"]*Red Hat', release, re.M):
        raise ValueError('Red Hat-modified JDKs cannot be used for this SafeLogic profile')
    if not (home / 'conf/security/java.security').is_file() or not (home / 'conf/security/java.policy').is_file():
        raise ValueError('JDK security configuration is incomplete: ' + str(home))
    # The provider-patched JDK is validated by the existing FIPS probes on reruns.
    # A pristine download is tested before being published as JAVA_HOME.
    return version[1]


def extract_archive(archive, target, major):
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    # log_init uses umask 077; the shared Java parent must remain traversable
    # by cloudera-scm, NiFi and Registry, unlike the private download cache.
    target.parent.chmod(0o755)
    with tempfile.TemporaryDirectory(prefix=target.name + '.stage.', dir=str(target.parent)) as tmp:
        stage = Path(tmp)
        with tarfile.open(archive) as tf:
            members = tf.getmembers()
            roots = set()
            names = set()
            symlinks = set()
            for member in members:
                name = PurePosixPath(member.name)
                if name.is_absolute() or '..' in name.parts or not name.parts:
                    raise ValueError('Unsafe JDK archive member: ' + member.name)
                if not (member.isdir() or member.isfile() or member.issym() or member.islnk()):
                    raise ValueError('Unsupported JDK archive member: ' + member.name)
                normal = str(name)
                if normal in names:
                    raise ValueError('Duplicate JDK archive member: ' + member.name)
                names.add(normal)
                roots.add(name.parts[0])
                if member.issym():
                    symlinks.add(normal)
                if member.issym() or member.islnk():
                    link = PurePosixPath(member.linkname)
                    resolved = PurePosixPath(posixpath.normpath(str(name.parent / link) if member.issym() else str(link)))
                    if link.is_absolute() or '..' in resolved.parts or not resolved.parts or resolved.parts[0] != name.parts[0]:
                        raise ValueError('Unsafe JDK archive link: ' + member.name)
            if len(roots) != 1:
                raise ValueError('JDK archive must contain exactly one top-level directory')
            for member in members:
                name = PurePosixPath(member.name)
                if any(str(parent) in symlinks for parent in name.parents):
                    raise ValueError('JDK archive writes through a symlink: ' + member.name)
                destination = stage.joinpath(*name.parts)
                if member.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with tf.extractfile(member) as src, destination.open('xb') as out:
                        shutil.copyfileobj(src, out)
                    destination.chmod(member.mode & 0o777)
            # Resolve links after all regular files exist. Hard links cannot target links.
            for member in sorted(members, key=lambda m: m.issym()):
                if member.issym() or member.islnk():
                    destination = stage.joinpath(*PurePosixPath(member.name).parts)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    if member.issym():
                        destination.symlink_to(member.linkname)
                    else:
                        source = stage.joinpath(*PurePosixPath(member.linkname).parts)
                        if source.is_symlink() or not source.is_file():
                            raise ValueError('JDK hard link does not target a regular file')
                        os.link(str(source), str(destination))
        home = stage / next(iter(roots))
        version = validate_home(home, major)
        clean_env = {key: value for key, value in os.environ.items()
                     if key not in ('JDK_JAVA_OPTIONS', 'JAVA_TOOL_OPTIONS', '_JAVA_OPTIONS')}
        result = subprocess.run([str(home / 'bin/java'), '-version'], env=clean_env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
        if result.returncode or not re.search(r'version\s+"' + str(major) + r'[."]', result.stdout):
            raise ValueError('Downloaded JDK failed its Java version probe: ' + result.stdout)
        if target.exists() or target.is_symlink():
            raise ValueError('Existing JDK target is incomplete or incompatible; it has been preserved: ' + str(target))
        # tar directory entries often use 0700. Every service must be able to traverse.
        for directory in [home] + [p for p in home.rglob('*') if p.is_dir() and not p.is_symlink()]:
            directory.chmod(0o755)
        home.rename(target)
        return version


def install_one(env, major, target, archive, checksum, downloads):
    target = Path(target)
    cache = Path(env['JAVA_DOWNLOAD_CACHE_DIR'])
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    if archive:
        if not re.fullmatch(r'[a-fA-F0-9]{64}', checksum) or digest(archive) != checksum.lower():
            raise ValueError('Configured local JDK archive SHA256 mismatch')
        metadata = {'major': int(major), 'name': Path(archive).name,
                    'url': 'local archive', 'sha256': checksum.lower()}
    elif target.exists() or target.is_symlink():
        version = validate_home(target, major)
        print('[OK] Reusing complete upstream JDK ' + version + ' at ' + str(target), flush=True)
        return
    else:
        if env['JAVA_AUTO_DOWNLOAD'] != 'true' or env['ALLOW_EXTERNAL'] != 'true':
            raise ValueError('Automatic upstream JDK download is disabled and no usable JDK is installed')
        lock = cache / ('jdk-' + str(major) + '.json')
        if lock.is_file():
            metadata = json.loads(lock.read_text())
            if metadata.get('major') != int(major) or metadata.get('architecture') != env['JAVA_DOWNLOAD_ARCH']:
                raise ValueError('Cached JDK metadata does not match the requested platform')
            if not re.fullmatch(r'[a-f0-9]{64}', metadata.get('sha256', '')) or Path(metadata.get('name', '')).name != metadata.get('name'):
                raise ValueError('Invalid cached JDK metadata')
            require_https(metadata['url'])
        else:
            query = urlencode({'architecture': env['JAVA_DOWNLOAD_ARCH'], 'image_type': 'jdk',
                               'os': 'linux', 'vendor': env['JAVA_DOWNLOAD_VENDOR'], 'heap_size': 'normal'})
            url = env['JAVA_DOWNLOAD_API_URL'].rstrip('/') + '/' + str(major) + '/hotspot?' + query
            with tempfile.TemporaryDirectory(dir=str(cache)) as tmp:
                path = Path(tmp) / 'assets.json'
                downloads.fetch(url, path)
                metadata = select_asset(json.loads(path.read_text()), major, env)
            atomic_json(lock, metadata)
        archive = cache / metadata['name']
        if not archive.is_file() or digest(archive) != metadata['sha256']:
            part = archive.with_name(archive.name + '.part')
            print('[INFO] Downloading verified upstream JDK ' + metadata['release'] + '...', flush=True)
            downloads.fetch(metadata['url'], part)
            if digest(part) != metadata['sha256']:
                part.unlink()
                raise ValueError('Downloaded JDK SHA256 differs from the vendor metadata')
            part.replace(archive)
    if target.exists() or target.is_symlink():
        version = validate_home(target, major)
        print('[OK] Reusing complete upstream JDK ' + version + ' at ' + str(target), flush=True)
        return
    version = extract_archive(archive, target, major)
    atomic_json(cache / ('jdk-' + str(major) + '-installed.json'), dict(metadata, home=str(target)))
    print('[OK] Installed upstream JDK ' + version + ' at ' + str(target), flush=True)


def install(env, downloads=None):
    downloads = downloads or Downloads(env)
    cache = Path(env['JAVA_DOWNLOAD_CACHE_DIR'])
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (cache / '.install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        install_one(env, env['JAVA_MAJOR'], env['JAVA_HOME_TARGET'], env.get('JAVA_ARCHIVE_FILE', ''),
                    env.get('JAVA_ARCHIVE_SHA256', ''), downloads)
        install_one(env, env['CFM_JAVA_MAJOR'], env['CFM_JAVA_HOME'], env.get('CFM_JAVA_ARCHIVE_FILE', ''),
                    env.get('CFM_JAVA_ARCHIVE_SHA256', ''), downloads)


if __name__ == '__main__':
    try:
        install(os.environ)
    except Exception as error:
        print('[ERROR] Automatic upstream JDK installation failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
