#!/usr/bin/env python3
"""Compile standalone and embedded Python; check profile shell references."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
count=0
for path in sorted(root.rglob('*.py')):
    compile(path.read_text(),str(path),'exec');count+=1
for path in sorted(root.rglob('*.sh')):
    lines=path.read_text().splitlines();index=0
    while index<len(lines):
        match=re.search(r"<<'?(PY[A-Z0-9_]*)'?", lines[index])
        if match:
            tag=match.group(1);start=index+1;end=start
            while end<len(lines) and lines[end]!=tag: end+=1
            if end==len(lines): raise SystemExit(f'Missing heredoc terminator {path}:{start}')
            compile('\n'.join(lines[start:end]),str(path)+':'+str(start+1),'exec');count+=1;index=end
        index+=1
for path in (root/'RUN_MANAGER',root/'RUN_AGENT'):
    for script in re.findall(r'\b(?:\d\d_[a-z_]+\.sh)\b',path.read_text()):
        candidate=path.parent/script
        if not candidate.is_file(): raise SystemExit(f'Broken script reference in {path}: {script}')
print(f'[OK] {count} standalone/embedded Python blocks and wrapper script references')
# The core is independently executable when the optional add-on is absent.
for path in [*root.rglob('*.sh'), *root.rglob('*.py'), root/'RUN_MANAGER',root/'RUN_AGENT',root/'EXPORTS']:
    if '/tests/' in str(path) or path.resolve()==Path(__file__).resolve():continue
    if any(value in path.read_text() for value in ('AUTO_TLS_', 'POSTGRES_TLS_SOURCE_', 'DB_CLIENT_CA_FILE', 'prepare_database_truststore', 'CM_CLUSTER_CA_FILE')):
        raise SystemExit('Standalone TLS dependency remains in core: '+str(path))
print('[OK] Core scripts have no optional TLS configuration dependency')
