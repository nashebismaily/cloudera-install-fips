#!/usr/bin/env python3
"""Check effective CM-generated configuration and actual running CFM JVM executables."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import socket


def load_properties(path):
    result={}
    for line in path.read_text().splitlines():
        line=line.strip()
        if line and not line.startswith(('#','!')) and '=' in line:
            name,value=line.split('=',1);result[name.strip()]=value.strip()
    return result


def inspect_properties(role, properties, bootstrap, env):
    prefix='nifi.' if role=='nifi' else 'nifi.registry.'
    expected={prefix+'security.keystoreType':'BCFKS',prefix+'security.truststoreType':'BCFKS'}
    if role=='nifi': expected[prefix+'sensitive.props.algorithm']=env['NIFI_SENSITIVE_PROPS_ALGORITHM']
    for key,value in expected.items():
        if properties.get(key,'').upper()!=value.upper(): raise ValueError('Incorrect effective setting: '+key)
    joined=' '.join(bootstrap.values())
    for required in (env['JAVA_FIPS_DIR'],'approved_only=true','allowGCMCiphers=true','trustStoreType=BCFKS'):
        if required not in joined: raise ValueError('Missing effective bootstrap option: '+required)
    if not properties.get(prefix+'web.https.port'): raise ValueError('HTTPS is not enabled for '+role)
    if properties.get(prefix+'web.http.port'): raise ValueError('Plain HTTP remains enabled for '+role)
    if role=='nifi' and len(properties.get(prefix+'sensitive.props.key',''))<int(env['MIN_FIPS_PASSWORD_LENGTH']):
        raise ValueError('Missing/short effective NiFi sensitive-properties key')
    for required in ('--module-path=', '--add-modules=', '--add-exports=',
                     '-Dcom.safelogic.cryptocomply.fips.approved_only=true',
                     '-Dorg.bouncycastle.fips.approved_only=true'):
        if required not in joined: raise ValueError('Missing effective bootstrap option: '+required)


def check_runtime(role, env):
    pattern=env['NIFI_PROCESS_GLOB'] if role=='nifi' else env['REGISTRY_PROCESS_GLOB']
    filename='nifi.properties' if role=='nifi' else 'nifi-registry.properties'
    candidates=[]
    for directory in Path(env['CM_AGENT_PROCESS_DIR']).glob(pattern):
        prop=directory/filename;boot=directory/'bootstrap.conf'
        if prop.is_file() and boot.is_file(): candidates.append((directory.stat().st_mtime,directory,prop,boot))
    if not candidates: raise ValueError('No CM-generated '+role+' process directory was found')
    _,directory,prop,boot=max(candidates,key=lambda item:item[0])
    properties=load_properties(prop);bootstrap=load_properties(boot)
    inspect_properties(role,properties,bootstrap,env)
    prefix='nifi.' if role=='nifi' else 'nifi.registry.'
    jvm=['-J'+v for v in shlex.split(env['AUTO_TLS_JAVA_OPTIONS'])]
    for kind in ('keystore','truststore'):
        path=properties.get(prefix+'security.'+kind)
        password=properties.get(prefix+'security.'+kind+'Passwd')
        if not path or not password: raise ValueError('Missing effective '+role+' '+kind+' path/password')
        secret_env=dict(os.environ,CFM_CHECK_STORE_PASSWORD=password)
        command=[str(Path(env['CFM_JAVA_HOME'])/'bin/keytool'),*jvm,'-list','-keystore',path,
                 '-storetype','BCFKS','-storepass:env','CFM_CHECK_STORE_PASSWORD']
        secret_env.pop('JDK_JAVA_OPTIONS',None)
        result=subprocess.run(command,env=secret_env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        if result.returncode: raise ValueError('Effective '+role+' '+kind+' cannot be loaded as BCFKS')
    needle=b'org.apache.nifi.NiFi' if role=='nifi' else b'org.apache.nifi.registry.NiFiRegistry'
    running=[]
    for pid in Path('/proc').glob('[0-9]*'):
        try:
            args=(pid/'cmdline').read_bytes().split(b'\0')
            if needle in args:
                executable=(pid/'exe').resolve()
                if executable != (Path(env['CFM_JAVA_HOME'])/'bin/java').resolve():
                    raise ValueError(role+' JVM is not using the configured JDK 21: pid='+pid.name)
                running.append(pid.name)
                process_environment=(pid/'environ').read_bytes()
                if role=='nifi' and b'HADOOP_SASL_MECHANISM=DIGEST-SHA' not in process_environment.split(b'\0'):
                    raise ValueError('NiFi JVM lacks HADOOP_SASL_MECHANISM=DIGEST-SHA')
                effective=b' '.join(args)+process_environment
                for required in (env['JAVA_FIPS_DIR'], 'com.safelogic.cryptocomply.fips.approved_only=true',
                                 'org.bouncycastle.fips.approved_only=true', 'allowGCMCiphers=true'):
                    if required.encode() not in effective:
                        raise ValueError(role+' running JVM lacks a FIPS option: '+required)
        except (FileNotFoundError,PermissionError,ProcessLookupError): continue
    if not running: raise ValueError('No running '+role+' JVM found')
    # A live handshake catches SAN, trust-chain, mutual-auth and cipher failures
    # that a syntactically correct bootstrap.conf cannot reveal.
    host=properties.get(prefix+'web.https.host','')
    if host in ('','0.0.0.0','::'):
        host=env.get('AGENT_HOST') or socket.getfqdn()
    secret_env=dict(os.environ)
    secret_env.pop('JDK_JAVA_OPTIONS',None)
    secret_env.update(CFM_PROBE_STORE_PASSWORD=properties[prefix+'security.keystorePasswd'],
                      CFM_PROBE_KEY_PASSWORD=properties.get(prefix+'security.keyPasswd') or properties[prefix+'security.keystorePasswd'],
                      CFM_PROBE_TRUST_PASSWORD=properties[prefix+'security.truststorePasswd'])
    command=[str(Path(env['CFM_JAVA_HOME'])/'bin/java'),*shlex.split(env['AUTO_TLS_JAVA_OPTIONS']),
             str(Path(__file__).parent/'TlsProbe.java'),properties[prefix+'security.keystore'],
             properties[prefix+'security.truststore'],host,properties[prefix+'web.https.port']]
    result=subprocess.run(command,env=secret_env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=60)
    if result.returncode:
        raise ValueError('Live '+role+' BCJSSE TLS handshake failed; check host SAN, CA trust, client/server EKUs and GCM settings. '+result.stderr[-1200:])
    print(result.stdout.strip())
    print('[OK] '+role+': JDK 21 process '+','.join(running)+', HTTPS, BCFKS stores and effective FIPS settings in '+str(directory))


if __name__=='__main__':
    try:
        roles=sys.argv[1].split(',')
        if any(role not in ('nifi','registry') for role in roles): raise ValueError('Roles must be nifi, registry, or nifi,registry')
        for role in roles: check_runtime(role,os.environ)
    except (OSError,ValueError) as error:
        raise SystemExit('[ERROR] '+str(error))
