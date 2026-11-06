#!/usr/bin/env python3
"""Verify SP1 SafeLogic JARs and original GNU/BSD/digest-only SHA256 sidecars."""
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import tempfile
import zipfile

CORE_CLASSES = {
    'ccj-4.0.0-fips.jar': 'com/safelogic/cryptocomply/jcajce/provider/CryptoComplyFipsProvider.class',
    'bctls-2.0.17.1.jar': 'org/bouncycastle/jsse/provider/BouncyCastleJsseProvider.class',
}
SASL_CLASS = 'com/cloudera/security/sasl/ClouderaSaslProvider.class'


def digest_file(path, algorithm='sha256'):
    value = hashlib.new(algorithm)
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def parse_digest(text, filename, size=64):
    text = text.strip()
    hexadecimal = r'[0-9a-fA-F]{' + str(size) + '}'
    if re.fullmatch(hexadecimal, text):
        return text.lower()
    match = re.fullmatch(r'(' + hexadecimal + r')\s+\*?(?:\./)?(.+)', text)
    if match and Path(match[2]).name == filename:
        return match[1].lower()
    match = re.fullmatch(r'(?:SHA256|SHA2-256|SHA512|SHA2-512|SHA1)\s*\((.+)\)\s*=\s*(' + hexadecimal + ')', text, flags=re.I)
    if match and Path(match[1]).name == filename:
        return match[2].lower()
    raise ValueError('Invalid or mismatched checksum sidecar for ' + filename)


def inspect_jar(path):
    with zipfile.ZipFile(path) as jar:
        if jar.testzip() is not None:
            raise ValueError('Corrupt JAR: ' + path.name)
        expected = CORE_CLASSES.get(path.name)
        if path.name.startswith('sasl-sha256aes-'):
            expected = SASL_CLASS
        if expected and expected not in jar.namelist():
            raise ValueError('Expected provider class missing from ' + path.name)


def validate_bundle(source, names, checksum_file=None, require_checksums=True):
    source = Path(source)
    combined = {}
    if checksum_file and Path(checksum_file).is_file():
        for line in Path(checksum_file).read_text().splitlines():
            if line.strip() and not line.startswith('#'):
                digest, name = line.split(maxsplit=1)
                name = name.lstrip('*').removeprefix('./')
                combined[name] = parse_digest(digest, name)
    for name in names:
        if Path(name).name != name or not name.endswith('.jar'):
            raise ValueError('FIPS JAR must be a basename: ' + name)
        path = source / name
        actual = digest_file(path)
        if require_checksums:
            sidecar = source / (name + '.sha256')
            expected = parse_digest(sidecar.read_text(), name) if sidecar.is_file() else combined.get(name)
            if expected != actual:
                raise ValueError('Missing or incorrect SHA256 for ' + name)
        inspect_jar(path)
        print('[OK] FIPS artifact integrity: ' + name)


def unpack_bundle(archive, destination, expected_names, expected_digest=''):
    """Extract verified regular JARs/sidecars, never links or paths from the archive."""
    archive, destination = Path(archive), Path(destination)
    if expected_digest and digest_file(archive) != parse_digest(expected_digest, archive.name):
        raise ValueError('SafeLogic archive SHA256 mismatch')
    allowed = set(expected_names) | {name + '.sha256' for name in expected_names}
    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp)
        seen = set()
        with tarfile.open(archive, 'r:*') as tf:
            for member in tf:
                path = PurePosixPath(member.name)
                if path.is_absolute() or '..' in path.parts or member.issym() or member.islnk() or member.isdev() or member.isfifo():
                    raise ValueError('Unsafe SafeLogic archive member: ' + member.name)
                if member.isdir():
                    continue
                if '__MACOSX' in path.parts or path.name.startswith('._') or path.name == '.DS_Store':
                    continue
                if not member.isfile() or path.name not in allowed:
                    raise ValueError('Unexpected SafeLogic bundle file: ' + member.name)
                if path.name in seen or member.size > 100 * 1024 * 1024:
                    raise ValueError('Duplicate/oversized SafeLogic bundle file: ' + member.name)
                seen.add(path.name)
                with tf.extractfile(member) as src, (stage / path.name).open('wb') as out:
                    shutil.copyfileobj(src, out)
        if seen != allowed:
            raise ValueError('Incomplete SafeLogic bundle; missing ' + ', '.join(sorted(allowed - seen)))
        validate_bundle(stage, expected_names)
        destination.mkdir(parents=True, exist_ok=True)
        for name in sorted(allowed):
            target = destination / name
            if target.exists() and target.read_bytes() != (stage / name).read_bytes():
                raise ValueError('Different artifact already staged: ' + str(target))
        for name in sorted(allowed):
            shutil.copyfile(stage / name, destination / name)
            (destination / name).chmod(0o644)


if __name__ == '__main__':
    try:
        names = [os.environ[n] for n in ('FIPS_CCJ_JAR', 'FIPS_BCTLS_JAR', 'FIPS_BCUTIL_JAR', 'FIPS_SASL_JAR')]
        names += os.environ.get('FIPS_EXTRA_JARS', '').split()
        validate_bundle(os.environ['FIPS_JAR_SOURCE_DIR'], names,
                        os.environ.get('FIPS_CHECKSUM_FILE'), os.environ['REQUIRE_FIPS_CHECKSUMS'] == 'true')
    except (OSError, ValueError, zipfile.BadZipFile, tarfile.TarError) as error:
        raise SystemExit('[ERROR] ' + str(error))
