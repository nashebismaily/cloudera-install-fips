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
for path in (root/'RUN_MANAGER',root/'RUN_AGENT',root/'utilities/tls/run_autotls.sh'):
    for script in re.findall(r'\b(?:\d\d_[a-z_]+\.sh)\b',path.read_text()):
        candidate=path.parent/script
        if not candidate.is_file(): raise SystemExit(f'Broken script reference in {path}: {script}')
print(f'[OK] {count} standalone/embedded Python blocks and wrapper script references')
orchestrator=(root/'utilities/tls/run_autotls.sh').read_text()
commands=set(re.findall(r'^  ([a-z][a-z-]+)\)',orchestrator,re.M))
for document in (root/'INSTALL.md',root/'utilities/tls/README.md'):
    for command in re.findall(r'run_autotls\.sh ([a-z][a-z-]+)',document.read_text()):
        if command not in commands:
            raise SystemExit(f'Invalid documented Auto-TLS command in {document}: {command}')
print('[OK] Documented Auto-TLS commands match the orchestrator')
