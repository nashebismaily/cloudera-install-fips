#!/usr/bin/env python3
"""Set the documented CM Java Home Directory for this host."""
import base64
import json
import os
import re
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def configure(env, manager, hostname):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*', manager):
        raise ValueError('Invalid CM server hostname')
    port = int(env['CM_RUNTIME_PORT'])
    if env['CM_RUNTIME_PROTOCOL'] != 'http' or not 1 <= port <= 65535:
        raise ValueError('Expected the configured CM HTTP endpoint')
    base = 'http://' + manager + ':' + str(port) + '/api'
    user, password = env['CM_ADMIN_USER'], env['CM_ADMIN_PASSWORD']
    if not user or not password:
        raise ValueError('CM API credentials are missing from EXPORTS')
    token = base64.b64encode((user + ':' + password).encode()).decode()
    opener = build_opener(ProxyHandler({}), NoRedirect())

    def request(path, data=None):
        body = json.dumps(data).encode() if data is not None else None
        headers = {'Authorization': 'Basic ' + token,
                   'Accept': 'text/plain' if path == '/version' else 'application/json'}
        if body is not None:
            headers['Content-Type'] = 'application/json'
        req = Request(base + path, data=body, headers=headers,
                      method='PUT' if body is not None else 'GET')
        with opener.open(req, timeout=int(env['TCP_CONNECT_TIMEOUT_SECONDS'])) as response:
            return response.read().decode()

    version = request('/version').strip().strip('"')
    if not re.fullmatch(r'v[0-9]+', version):
        raise ValueError('Unexpected CM API version response')
    target = hostname.rstrip('.').lower()
    for attempt in range(10):
        hosts = json.loads(request('/' + version + '/hosts?view=summary'))['items']
        matches = [host for host in hosts if host['hostname'].rstrip('.').lower() == target]
        if len(matches) == 1:
            break
        if len(matches) > 1:
            raise ValueError('More than one CM host record matches ' + hostname)
        if attempt < 9:
            time.sleep(2)
    else:
        raise ValueError('CM has not registered ' + hostname)

    path = '/' + version + '/hosts/' + quote(matches[0]['hostId'], safe='') + '/config'
    home = env['JAVA_HOME_TARGET']
    def configured_home():
        config = json.loads(request(path))['items']
        return next((item.get('value') for item in config if item['name'] == 'java_home'), None)

    if configured_home() != home:
        request(path, {'items': [{'name': 'java_home', 'value': home}]})
        if configured_home() != home:
            raise ValueError('CM did not retain Java Home Directory for ' + hostname)
    print('[OK] CM Java Home Directory for ' + hostname + ' = ' + home)


if __name__ == '__main__':
    try:
        configure(os.environ, sys.argv[1], sys.argv[2])
    except HTTPError as error:
        print('[WARN] CM Java Home update returned HTTP ' + str(error.code), file=sys.stderr)
        sys.exit(1)
    except (URLError, OSError, ValueError, KeyError) as error:
        print('[WARN] CM Java Home update failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
