#!/usr/bin/env python3
"""Extract relevant real CSD parameter names for the pinned build, without guessing API keys."""
import json
import os
from pathlib import Path
import re
import sys
import zipfile


def parse_descriptor(content):
    try:
        return json.loads(content)
    except json.JSONDecodeError:
        # Some SDLs contain C-style comments. Keep quoted text, including URLs,
        # and preserve line and column positions when removing comments.
        def remove_comment(match):
            token = match.group()
            if token.startswith('"'):
                return token
            return re.sub(r'[^\r\n]', ' ', token)

        tokens = r'"(?:[^"\\]|\\.)*"|//[^\r\n]*|/\*[\s\S]*?\*/'
        return json.loads(re.sub(tokens, remove_comment, content.decode('utf-8-sig')))


def parameters(value, result):
    if isinstance(value, dict):
        if 'name' in value and ('label' in value or 'type' in value):
            text = str(value.get('name', '')) + ' ' + str(value.get('label', '')) + ' ' + str(value.get('description', ''))
            if re.search(r'jdk|java home|safety|advanced configuration|identity|python|jdbc|database|keystore|truststore|ssl|tls|secure', text, re.I):
                result.append({key: value[key] for key in ('name', 'label', 'type', 'description') if key in value})
        for child in value.values():
            parameters(child, result)
    elif isinstance(value, list):
        for child in value:
            parameters(child, result)


if __name__ == '__main__':
    result = {}
    for name in (os.environ['CFM_NIFI_CSD_JAR'], os.environ['CFM_NIFIREGISTRY_CSD_JAR']):
        try:
            with zipfile.ZipFile(Path(os.environ['ARTIFACT_CACHE_DIR']) / name) as archive:
                descriptor = parse_descriptor(archive.read('descriptor/service.sdl'))
        except (OSError, KeyError, ValueError, zipfile.BadZipFile) as exc:
            print(f'[WARN] CSD field reference unavailable for {name}: {exc}', file=sys.stderr)
            continue
        fields = []
        parameters(descriptor, fields)
        result[name] = fields
    path = Path(os.environ['CFM_GENERATED_CONFIG_DIR']) / 'actual-csd-fields.json'
    path.write_text(json.dumps(result, indent=2) + '\n')
    path.chmod(0o600)
    if result:
        print('[OK] Actual release CSD field names: ' + str(path))

