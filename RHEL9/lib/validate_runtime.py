#!/usr/bin/env python3
"""Validate the effective HTTP lab configuration, real JVMs and HTTP responses."""
import os
from pathlib import Path
import socket
import sys
from urllib.request import build_opener,HTTPRedirectHandler,ProxyHandler
from urllib.parse import urlsplit


def load_properties(path):
    result={}
    for line in path.read_text().splitlines():
        line=line.strip()
        if line and not line.startswith(('#','!')) and '=' in line:
            name,value=line.split('=',1);result[name.strip()]=value.strip()
    return result


def inspect_properties(role,properties,bootstrap,env):
    prefix='nifi.' if role=='nifi' else 'nifi.registry.'
    if not properties.get(prefix+'web.http.port'):raise ValueError('HTTP is not enabled for '+role)
    if properties.get(prefix+'web.https.port'):raise ValueError('HTTPS remains enabled for '+role)
    for key in ('security.keystore','security.truststore'):
        if properties.get(prefix+key):raise ValueError('Unexpected certificate store in HTTP lab: '+prefix+key)
    if role=='nifi':
        if properties.get('nifi.sensitive.props.algorithm')!=env['NIFI_SENSITIVE_PROPS_ALGORITHM']:
            raise ValueError('Incorrect effective sensitive-properties algorithm')
        if len(properties.get('nifi.sensitive.props.key',''))<int(env['MIN_FIPS_PASSWORD_LENGTH']):
            raise ValueError('Missing/short effective NiFi sensitive-properties key')
        for key in ('nifi.cluster.protocol.is.secure','nifi.remote.input.secure','nifi.zookeeper.client.secure'):
            if properties.get(key,'false').lower()!='false':raise ValueError('Encrypted transport remains enabled: '+key)
        if properties.get('nifi.security.user.login.identity.provider'):
            raise ValueError('HTTP lab must not select an authentication provider')
    joined=' '.join(bootstrap.values())
    for required in (env['JAVA_FIPS_DIR'],'--module-path=','--add-modules=','--add-exports=',
                     '-Dcom.safelogic.cryptocomply.fips.approved_only=true',
                     '-Dorg.bouncycastle.fips.approved_only=true'):
        if required not in joined:raise ValueError('Missing effective bootstrap option: '+required)


class HttpOnlyRedirect(HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        if urlsplit(newurl).scheme!='http':raise ValueError('HTTP service redirected to a non-HTTP endpoint')
        return super().redirect_request(req,fp,code,msg,headers,newurl)


def check_runtime(role,env):
    pattern=env['NIFI_PROCESS_GLOB'] if role=='nifi' else env['REGISTRY_PROCESS_GLOB']
    filename='nifi.properties' if role=='nifi' else 'nifi-registry.properties'
    candidates=[]
    for directory in Path(env['CM_AGENT_PROCESS_DIR']).glob(pattern):
        prop=directory/filename;boot=directory/'bootstrap.conf'
        if prop.is_file() and boot.is_file():candidates.append((directory.stat().st_mtime,directory,prop,boot))
    if not candidates:raise ValueError('No CM-generated '+role+' process directory was found')
    _,directory,prop,boot=max(candidates,key=lambda item:item[0])
    properties=load_properties(prop);bootstrap=load_properties(boot)
    inspect_properties(role,properties,bootstrap,env)
    needle=b'org.apache.nifi.NiFi' if role=='nifi' else b'org.apache.nifi.registry.NiFiRegistry'
    running=[]
    for pid in Path(env.get('PROC_ROOT','/proc')).glob('[0-9]*'):
        try:
            args=(pid/'cmdline').read_bytes().split(b'\0')
            if needle not in args:continue
            if (pid/'exe').resolve()!=(Path(env['CFM_JAVA_HOME'])/'bin/java').resolve():
                raise ValueError(role+' JVM is not using configured JDK21: pid='+pid.name)
            process_environment=(pid/'environ').read_bytes()
            if role=='nifi' and b'HADOOP_SASL_MECHANISM=DIGEST-SHA' not in process_environment.split(b'\0'):
                raise ValueError('NiFi JVM lacks HADOOP_SASL_MECHANISM=DIGEST-SHA')
            effective=b' '.join(args)+process_environment
            for required in (env['JAVA_FIPS_DIR'],'com.safelogic.cryptocomply.fips.approved_only=true',
                             'org.bouncycastle.fips.approved_only=true'):
                if required.encode() not in effective:raise ValueError(role+' running JVM lacks a FIPS option: '+required)
            running.append(pid.name)
        except (FileNotFoundError,PermissionError,ProcessLookupError):continue
    if not running:raise ValueError('No running '+role+' JVM found')
    prefix='nifi.' if role=='nifi' else 'nifi.registry.'
    host=properties.get(prefix+'web.http.host','')
    if host in ('','0.0.0.0','::'):host=env.get('AGENT_HOST') or socket.getfqdn()
    port=properties[prefix+'web.http.port']
    endpoint='/nifi/' if role=='nifi' else '/nifi-registry/'
    opener=build_opener(ProxyHandler({}),HttpOnlyRedirect())
    with opener.open('http://'+host+':'+port+endpoint,timeout=20) as response:
        if response.status!=200:raise ValueError(role+' HTTP UI did not return success')
    print('[OK] '+role+': JDK21 process '+','.join(running)+', HTTP response and effective FIPS settings in '+str(directory))


if __name__=='__main__':
    try:
        roles=sys.argv[1].split(',')
        if any(role not in ('nifi','registry') for role in roles):raise ValueError('Roles must be nifi, registry, or nifi,registry')
        for role in roles:check_runtime(role,os.environ)
    except (OSError,ValueError) as error:
        raise SystemExit('[ERROR] '+str(error))
