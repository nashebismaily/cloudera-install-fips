#!/usr/bin/env python3
"""Resolve entitled artifacts and lock builds; never choose a newer product release."""
import base64
from datetime import datetime, timezone
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import shlex
import ssl
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPSHandler, HTTPRedirectHandler
import zipfile

from fips_artifacts import digest_file, inspect_jar, parse_digest, unpack_bundle, validate_bundle


class SameOriginRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urlsplit(newurl).scheme != 'https' or urlsplit(newurl).netloc != urlsplit(req.full_url).netloc:
            raise ValueError('Refused cross-origin/non-HTTPS artifact redirect')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class ArchiveClient:
    def __init__(self, env):
        self.env = env
        self.opener = build_opener(HTTPSHandler(context=ssl.create_default_context()), SameOriginRedirect())

    def get(self, url, limit=100 * 1024 * 1024):
        parsed = urlsplit(url)
        if parsed.scheme != 'https' or parsed.username or parsed.password:
            raise ValueError('Archive URLs must use HTTPS without embedded credentials')
        auth = base64.b64encode((self.env['CLOUDERA_REPO_USER'] + ':' + self.env['CLOUDERA_REPO_PASS']).encode()).decode()
        for attempt in range(int(self.env['ARTIFACT_DOWNLOAD_RETRIES'])):
            try:
                with self.opener.open(Request(url, headers={'Authorization': 'Basic ' + auth}),
                                      timeout=int(self.env['ARTIFACT_DOWNLOAD_TIMEOUT'])) as response:
                    data = response.read(limit + 1)
                    if len(data) > limit:
                        raise ValueError('Artifact response exceeds the size limit')
                    return data
            except HTTPError as error:
                if error.code < 500:
                    raise
            except (URLError, TimeoutError):
                pass
            if attempt + 1 < int(self.env['ARTIFACT_DOWNLOAD_RETRIES']):
                time.sleep(min(2 ** attempt, 5))
        raise ValueError('Cannot download release artifact; check entitlement, proxy, CA trust and connectivity')


class Links(HTMLParser):
    def __init__(self, text):
        super().__init__(); self.links = []; self.feed(text)

    def handle_starttag(self, tag, attrs):
        if tag == 'a':
            self.links.extend(value for key, value in attrs if key == 'href' and value)


def basename(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]+', value):
        raise ValueError('Unsafe artifact basename')
    return value


def select_parcel(document, env, product):
    if product == 'CFM':
        pattern = re.compile(r'^CFM-' + re.escape(env['CFM_VERSION']) + r'-(\d+)-el9\.parcel$')
    else:
        pattern = re.compile(r'^CDH-7\.3\.2[^/]*-el9\.parcel$')
    matches = []
    for parcel in document.get('parcels', []):
        name = parcel.get('parcelName', '')
        match = pattern.fullmatch(name)
        if not match:
            continue
        if product == 'CFM' and env.get('CFM_BUILD') and match[1] != env['CFM_BUILD']:
            continue
        basename(name)
        digest = parcel.get('hash', '')
        if not re.fullmatch(r'(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})', digest):
            raise ValueError('Missing/invalid parcel hash in ' + product + ' manifest')
        matches.append({'name': name, 'hash': digest.lower()})
    if len(matches) != 1:
        raise ValueError('Expected one matching ' + product + ' EL9 parcel, found ' + str(len(matches)) +
                         '; inspect the entitled manifest and pin the build explicitly if ambiguous')
    return matches[0]


def profile(env):
    return {key: env[key] for key in ('PROFILE_NAME', 'CM_VERSION', 'CDP_RUNTIME_VERSION', 'CFM_VERSION',
                                     'NIFI_VERSION', 'EXPECTED_RHEL_MAJOR', 'EXPECTED_RHEL_MINOR')}


def load_lock(env):
    path = Path(env['ARTIFACT_LOCK_FILE'])
    if not path.is_file():
        return None
    data = json.loads(path.read_text())
    if data.get('profile') != profile(env):
        raise ValueError('Artifact lock belongs to another profile; use a new ARTIFACT_STATE_DIR for a reviewed version change')
    for value in (data['cfm']['name'], data['cdp']['name'], data['sasl']['name'], *data['csds']):
        basename(value)
    if env.get('CFM_BUILD') and env['CFM_BUILD'] != data['cfm']['build']:
        raise ValueError('CFM_BUILD conflicts with the existing artifact lock')
    return data


def atomic_write(path, data):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(data); handle.flush(); os.fsync(handle.fileno())
    temporary.chmod(0o600)
    temporary.replace(path)


def verify_csd(path):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None or 'descriptor/service.sdl' not in archive.namelist():
            raise ValueError('Invalid Cloudera CSD archive: ' + path.name)


def stage_sasl(env, client):
    source = Path(env['FIPS_JAR_SOURCE_DIR'])
    expression = re.compile(r'^sasl-sha256aes-0\.1\.0\.' + re.escape(env['CDP_RUNTIME_VERSION']) + r'-(\d+)\.jar$')
    explicit = env.get('FIPS_SASL_JAR', '')
    if explicit and not expression.fullmatch(explicit):
        raise ValueError('FIPS_SASL_JAR must match the pinned CDP SP1 release')
    local = list(source.glob(env['FIPS_SASL_JAR_GLOB']))
    if explicit:
        local = [source / explicit] if (source / explicit).is_file() else []
    if len(local) > 1:
        raise ValueError('Multiple staged SASL builds; set FIPS_SASL_JAR explicitly')
    if local:
        path = local[0]; basename(path.name)
        if not expression.fullmatch(path.name):
            raise ValueError('Staged SASL does not match pinned CDP')
        if env.get('FIPS_SASL_SHA256'):
            if digest_file(path) != parse_digest(env['FIPS_SASL_SHA256'], path.name):
                raise ValueError('Staged SASL SHA256 mismatch')
            atomic_write(source / (path.name + '.sha256'), (digest_file(path) + '\n').encode())
        validate_bundle(source, [path.name], env.get('FIPS_CHECKSUM_FILE'))
        return {'name': path.name, 'sha256': digest_file(path), 'provenance': 'staged artifact with supplied SHA256'}
    root = env['FIPS_SASL_REPOSITORY_URL'].rstrip('/') + '/'
    if explicit:
        version = explicit[len('sasl-sha256aes-'):-4]
    else:
        listing = client.get(root, limit=5 * 1024 * 1024).decode()
        pattern = re.compile(r'^0\.1\.0\.' + re.escape(env['CDP_RUNTIME_VERSION']) + r'-\d+$')
        candidates = {urlsplit(href).path.rstrip('/').rsplit('/', 1)[-1] for href in Links(listing).links}
        versions = sorted(version for version in candidates if pattern.fullmatch(version))
        if len(versions) != 1:
            raise ValueError('Expected one release-matched SASL build in Maven listing; set FIPS_SASL_JAR explicitly or stage its approved file/sidecar')
        version = versions[0].rstrip('/')
    name = explicit or 'sasl-sha256aes-' + version + '.jar'
    basename(name)
    url = root + version + '/' + name
    content = client.get(url)
    expected = env.get('FIPS_SASL_SHA256', '')
    provenance = 'authenticated HTTPS download; SHA256 recorded locally'
    if expected:
        expected = parse_digest(expected, name)
        provenance = 'authenticated HTTPS + supplied SHA256'
    else:
        try:
            expected = parse_digest(client.get(url + '.sha256', limit=4096).decode(), name)
            provenance = 'authenticated HTTPS + archive SHA256 sidecar'
        except HTTPError as error:
            if error.code not in (403, 404):
                raise
    import hashlib
    actual = hashlib.sha256(content).hexdigest()
    if expected and actual != expected:
        raise ValueError('Downloaded SASL SHA256 mismatch')
    with tempfile.TemporaryDirectory() as tmp:
        staged = Path(tmp) / name; staged.write_bytes(content); inspect_jar(staged)
    atomic_write(source / name, content)
    atomic_write(source / (name + '.sha256'), (actual + '\n').encode())
    return {'name': name, 'sha256': actual, 'provenance': provenance, 'url': url}


def prepare(env, client=None):
    client = client or ArchiveClient(env)
    source = Path(env['FIPS_JAR_SOURCE_DIR'])
    names = [env[key] for key in ('FIPS_CCJ_JAR', 'FIPS_BCTLS_JAR', 'FIPS_BCUTIL_JAR')]
    names += env['FIPS_EXTRA_JARS'].split()
    archive = Path(env['FIPS_BUNDLE_ARCHIVE']) if env.get('FIPS_BUNDLE_ARCHIVE') else None
    if archive and archive.is_file():
        unpack_bundle(archive, source, names, env.get('FIPS_BUNDLE_SHA256', ''))
    validate_bundle(source, names, env.get('FIPS_CHECKSUM_FILE'))
    previous = load_lock(env)
    if previous:
        env = dict(env, FIPS_SASL_JAR=previous['sasl']['name'])
    sasl = stage_sasl(env, client)
    if previous and sasl['sha256'] != previous['sasl']['sha256']:
        raise ValueError('SASL changed since the deployment was locked')
    if previous:
        sasl = previous['sasl']  # Preserve the original checksum/download provenance.
    if b'<repomd' not in client.get(env['CM_REPO_METADATA_URL'], limit=5 * 1024 * 1024):
        raise ValueError('CM endpoint did not return repository metadata')
    cache = Path(env['ARTIFACT_CACHE_DIR']); cache.mkdir(parents=True, exist_ok=True)
    parcels = {}
    for product, url in (('CFM', env['CFM_MANIFEST_URL']), ('CDH', env['CDP_PARCEL_REPO_URL'] + 'manifest.json')):
        content = client.get(url, limit=10 * 1024 * 1024)
        parcels[product] = select_parcel(json.loads(content), env, product)
        atomic_write(cache / (product + '-manifest.json'), content)
    cfm, cdp = parcels['CFM'], parcels['CDH']
    cfm['build'] = re.fullmatch(r'CFM-' + re.escape(env['CFM_VERSION']) + r'-(\d+)-el9\.parcel', cfm['name'])[1]
    if previous and (cfm != previous['cfm'] or cdp != previous['cdp']):
        raise ValueError('Repository parcel changed since the deployment was locked; review before proceeding')
    csds = {}
    for service in ('NIFI', 'NIFIREGISTRY'):
        name = service + '-' + env['NIFI_VERSION'] + '.' + env['CFM_VERSION'] + '-' + cfm['build'] + '.jar'
        basename(name)
        content = client.get(env['CFM_CSD_BASE_URL'].rstrip('/') + '/' + name)
        target = cache / name; atomic_write(target, content); verify_csd(target)
        csds[name] = digest_file(target)
        if previous and previous['csds'].get(name) != csds[name]:
            raise ValueError('CSD changed since the deployment was locked: ' + name)
    data = {'profile': profile(env), 'resolved_at': datetime.now(timezone.utc).isoformat(),
            'cfm': cfm, 'cdp': cdp, 'sasl': sasl, 'csds': csds,
            'bundle_sha256': {name: digest_file(source / name) for name in names}}
    if previous and data['bundle_sha256'] != previous['bundle_sha256']:
        raise ValueError('SafeLogic bundle changed since the deployment was locked')
    atomic_write(env['ARTIFACT_LOCK_FILE'], (json.dumps(data, indent=2) + '\n').encode())
    print('[OK] Locked CM, CDP/CFM EL9 parcels, matching CSDs, seven SafeLogic JARs and SASL')
    print('[OK] CFM parcel: ' + cfm['name'])
    print('[OK] SASL: ' + sasl['name'] + ' (' + sasl['provenance'] + ')')


def shell_exports(env):
    data = load_lock(env)
    if not data:
        return ''
    cfm_name = data['cfm']['name'][:-len('-el9.parcel')]
    values = {'CFM_BUILD': data['cfm']['build'], 'CFM_PARCEL_FILE': data['cfm']['name'],
              'CFM_PARCEL_DIR_NAME': cfm_name, 'CFM_PARCEL_ROOT': env['CLOUDERA_PARCELS_DIR'].rstrip('/') + '/' + cfm_name,
              'CDP_PARCEL_FILE': data['cdp']['name'],
              'CDP_PARCEL_DIR_NAME': data['cdp']['name'][:-len('-el9.parcel')], 'FIPS_SASL_JAR': data['sasl']['name']}
    for service, key in (('NIFI', 'CFM_NIFI_CSD_JAR'), ('NIFIREGISTRY', 'CFM_NIFIREGISTRY_CSD_JAR')):
        names = [name for name in data['csds'] if name.startswith(service + '-')]
        if len(names) != 1:
            raise ValueError('Invalid CSD artifact lock')
        values[key] = names[0]
        values[key.replace('_JAR', '_URL')] = env['CFM_CSD_BASE_URL'].rstrip('/') + '/' + names[0]
    for service in ('TOOLKIT', 'REGISTRY', 'NIFI'):
        values['CFM_' + service + '_LIB_DIR'] = values['CFM_PARCEL_ROOT'] + '/' + service + '/lib'
    return '\n'.join('export ' + key + '=' + shlex.quote(value) for key, value in values.items())


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['--shell']:
            print(shell_exports(os.environ))
        else:
            os.umask(0o077); prepare(os.environ)
    except HTTPError as error:
        raise SystemExit('[ERROR] Cloudera archive HTTP ' + str(error.code) + '; check entitled access to every pinned product release')
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        raise SystemExit('[ERROR] ' + str(error))
