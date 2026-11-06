#!/usr/bin/env python3
"""Render the standard HTTP lab's CFM settings. No certificate inputs are used."""
import json
import os
from pathlib import Path
import xml.etree.ElementTree as ET


def properties(items):
    fragments=[]
    for name,value in items.items():
        node=ET.Element('property');ET.SubElement(node,'name').text=name;ET.SubElement(node,'value').text=value
        fragments.append(ET.tostring(node,encoding='unicode'))
    return '\n'.join(fragments)+'\n'


def render(env):
    opts={
        'java.arg.fips.modulepath':'--module-path='+env['JAVA_FIPS_DIR'],
        'java.arg.fips.modules':'--add-modules='+env['JAVA_FIPS_MODULES'],
        'java.arg.fips.exports':'--add-exports='+env['JAVA_FIPS_ADD_EXPORT']+'='+env['JAVA_FIPS_CCJ_MODULE'],
        'java.arg.fips.ccj':'-Dcom.safelogic.cryptocomply.fips.approved_only=true',
        'java.arg.fips.bc':'-Dorg.bouncycastle.fips.approved_only=true',
    }
    nifi={
        'nifi.sensitive.props.algorithm':env['NIFI_SENSITIVE_PROPS_ALGORITHM'],
        'nifi.sensitive.props.key':env['NIFI_SENSITIVE_PROPS_KEY'],
        'nifi.web.http.host':env['NIFI_HTTP_BIND_HOST'],
        'nifi.web.http.port':env['NIFI_HTTP_PORT'],
        'nifi.web.https.host':'','nifi.web.https.port':'',
        'nifi.security.keystore':'','nifi.security.keystoreType':'',
        'nifi.security.keystorePasswd':'','nifi.security.keyPasswd':'',
        'nifi.security.truststore':'','nifi.security.truststoreType':'','nifi.security.truststorePasswd':'',
        'nifi.security.user.login.identity.provider':'','nifi.security.user.authorizer':'',
        'nifi.security.allow.anonymous.authentication':'true',
        'nifi.cluster.protocol.is.secure':'false',
        'nifi.remote.input.secure':'false','nifi.zookeeper.client.secure':'false',
        'nifi.autogen.node.identities':'false',
        'nifi.python.command':env['NIFI_PYTHON_BIN'],
    }
    registry={
        'nifi.registry.web.http.host':env['NIFI_REGISTRY_HTTP_BIND_HOST'],
        'nifi.registry.web.http.port':env['NIFI_REGISTRY_HTTP_PORT'],
        'nifi.registry.web.https.host':'','nifi.registry.web.https.port':'',
        'nifi.registry.security.keystore':'','nifi.registry.security.keystoreType':'',
        'nifi.registry.security.keystorePasswd':'','nifi.registry.security.keyPasswd':'',
        'nifi.registry.security.truststore':'','nifi.registry.security.truststoreType':'',
        'nifi.registry.security.truststorePasswd':'',
        'nifi.registry.security.needClientAuth':'false',
        'nifi.registry.security.authorizer':'','nifi.registry.security.identity.provider':'',
    }
    settings={
        'Cloudera Manager':{'HTTP port':env['CM_HTTP_PORT'],'web_tls':False,'agent_tls':False,'Auto-TLS':False},
        'CDP Runtime':{'Enable TLS/SSL':False,'ZooKeeper client encryption':False,
                       'ZooKeeper quorum encryption':False,'Kerberos authentication':False,
                       'web interfaces':'HTTP','HDFS HTTP policy':'HTTP_ONLY'},
        'NiFi':{'nifi.jdk.home':env['CFM_JAVA_HOME'],'Enable TLS/SSL':False,
                'bootstrap safety valve':'nifi-bootstrap.xml','nifi.properties safety valve':'nifi-properties.xml',
                'service environment safety valve':'nifi-environment.txt','HTTP port':env['NIFI_HTTP_PORT'],
                'authentication':'HTTP: unauthenticated; no initial admin identity'},
        'NiFi Registry':{'nifi.registry.jdk.home':env['CFM_JAVA_HOME'],'Enable TLS/SSL':False,
                'bootstrap safety valve':'registry-bootstrap.xml','properties safety valve':'registry-properties.xml',
                'HTTP port':env['NIFI_REGISTRY_HTTP_PORT'],'JDBC URL':env['REGISTRY_DB_JDBC_URL'],
                'JDBC driver':'org.postgresql.Driver','JDBC driver directory':env['POSTGRES_JDBC_DIR'],
                'database user':env['REG_DB_USER'],'database password source':'REG_DB_PASS in EXPORTS',
                'authentication':'HTTP: unauthenticated'},
        'Reports Manager':{'database host':env['DB_HOST'],'database port':env['DB_PORT'],
                'database':env['RM_DB_NAME'],'database user':env['RM_DB_USER'],
                'database password source':'RM_DB_PASS in EXPORTS','Use SSL':False},
        'instructions':['Apply all settings to every applicable role configuration group before first start.',
                'Turn off TLS/SSL in the exposed CM service settings as well as applying the property snippets.',
                'Leave initial-admin identities and certificate fields empty in this HTTP profile.',
                'Keep the intended sensitive-properties key on every node; do not rotate a deployed key casually.']}
    return {'nifi-bootstrap.xml':properties(opts),'registry-bootstrap.xml':properties(opts),
            'nifi-properties.xml':properties(nifi),'registry-properties.xml':properties(registry),
            'nifi-environment.txt':'HADOOP_SASL_MECHANISM=DIGEST-SHA\n',
            'service-settings.json':json.dumps(settings,indent=2)+'\n'}


if __name__=='__main__':
    os.umask(0o077)
    target=Path(os.environ['CFM_GENERATED_CONFIG_DIR']);target.mkdir(parents=True,exist_ok=True);target.chmod(0o700)
    for name,content in render(os.environ).items():
        path=target/name;path.write_text(content);path.chmod(0o600)
