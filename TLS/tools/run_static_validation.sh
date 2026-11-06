#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"
while IFS= read -r -d '' file; do bash -n "${file}"; done < <(find . -type f \( -name '*.sh' -o -name EXPORTS \) -print0)
python3 - <<'PY'
from pathlib import Path
import re
root=Path.cwd();count=0
for path in root.rglob('*.py'):
    compile(path.read_text(),str(path),'exec');count+=1
for path in root.rglob('*.sh'):
    lines=path.read_text().splitlines();index=0
    while index<len(lines):
        match=re.search(r"<<'?(PY[A-Z0-9_]*)'?",lines[index])
        if match:
            tag=match.group(1);start=index+1;end=start
            while end<len(lines) and lines[end]!=tag:end+=1
            if end==len(lines):raise SystemExit('Missing heredoc terminator in '+str(path))
            compile('\n'.join(lines[start:end]),str(path)+':'+str(start+1),'exec');count+=1;index=end
        index+=1
# Standalone means no source/import of another installation directory.
for path in root.rglob('*.sh'):
    if path==root/'tools/run_static_validation.sh':continue
    if 'RHEL9/EXPORTS' in path.read_text() or '../RHEL9/' in path.read_text():
        raise SystemExit('Core dependency in optional TLS module: '+str(path))
print('[OK] Standalone TLS syntax/Python blocks:',count)
PY
python3 -m unittest discover -s tests -p 'test_*.py' -v
