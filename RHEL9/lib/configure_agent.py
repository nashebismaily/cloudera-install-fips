#!/usr/bin/env python3
"""Update only the agent's General section, preserving comments/other sections."""
import os
from pathlib import Path
import re
import sys


def configure(text,host,port):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*',host):raise ValueError('Invalid manager hostname')
    values={'server_host':host,'server_port':port,'use_tls':'0'}
    lines=text.splitlines(keepends=True);out=[];inside=False;found=False;written=set()
    def remaining():
        for key,value in values.items():
            if key not in written:out.append(key+'='+value+'\n');written.add(key)
    for line in lines:
        section=re.match(r'^\s*\[([^]]+)\]',line)
        if section:
            if inside:remaining()
            inside=section[1].lower()=='general';found|=inside
        match=re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=',line) if inside else None
        if match and match[1] in values:
            key=match[1]
            if key not in written:out.append(key+'='+values[key]+'\n');written.add(key)
        else:out.append(line if line.endswith('\n') else line+'\n')
    if inside:remaining()
    if not found:out.extend(['\n[General]\n']+[key+'='+value+'\n' for key,value in values.items()])
    return ''.join(out)


if __name__=='__main__':
    path=Path(os.environ['CM_AGENT_CONFIG_FILE'])
    path.write_text(configure(path.read_text(),sys.argv[1],os.environ['CM_AGENT_PORT']))
