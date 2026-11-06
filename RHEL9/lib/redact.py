#!/usr/bin/env python3
"""Filter known configured secrets from a vendor tool's stdout/stderr."""
import os, sys
secrets = sorted({v for k,v in os.environ.items() if ('PASSWORD' in k or k.endswith('_PASS')) and v},key=len,reverse=True)
for line in sys.stdin:
    for secret in secrets: line=line.replace(secret,'[REDACTED]')
    print(line,end='',flush=True)
