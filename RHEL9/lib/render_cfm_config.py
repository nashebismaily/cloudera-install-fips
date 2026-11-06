#!/usr/bin/env python3
"""Render complete CFM 4.x FIPS configuration without guessing CM service identities."""
import json
import os
from pathlib import Path
import xml.etree.ElementTree as ET


def properties(items):
    fragments=[]
    for name,value in items.items():
        node=ET.Element('property'); ET.SubElement(node,'name').text=name; ET.SubElement(node,'value').text=value
        fragments.append(ET.tostring(node,encoding='unicode'))
    return '\n'.join(fragments)+'\n'


def render(env):
    opts = {
        'java.arg.fips.modulepath':'--module-path='+env['JAVA_FIPS_DIR'],
        'java.arg.fips.modules':'--add-modules='+env['JAVA_FIPS_MODULES'],
        'java.arg.fips.exports':'--add-exports='+env['JAVA_FIPS_ADD_EXPORT']+'='+env['JAVA_FIPS_CCJ_MODULE'],
        'java.arg.fips.ccj':'-Dcom.safelogic.cryptocomply.fips.approved_only=true',
        'java.arg.fips.bc':'-Dorg.bouncycastle.fips.approved_only=true',
        'java.arg.fips.gcm':'-Dorg.bouncycastle.jsse.fips.allowGCMCiphers=true',
        'java.arg.fips.truststoretype':'-Djavax.net.ssl.trustStoreType=BCFKS',
        'java.arg.fips.truststore':'-Djavax.net.ssl.trustStore='+env['NIFI_TRUSTSTORE_PATH'],
        'java.arg.fips.trustpassword':'-Djavax.net.ssl.trustStorePassword='+env['NIFI_TRUSTSTORE_PASSWORD'],
    }
    settings={
        'NiFi':{'nifi.jdk.home':env['CFM_JAVA_HOME'], 'bootstrap safety valve':'nifi-bootstrap.xml',
                'nifi.properties safety valve':'nifi-properties.xml', 'service environment safety valve':'nifi-environment.txt',
                'Initial Admin Identity':env['NIFI_INITIAL_ADMIN_IDENTITY'],
                'node DN prefix':env['NIFI_NODE_DN_PREFIX'], 'node DN suffix':env['NIFI_NODE_DN_SUFFIX']},
        'NiFi Registry':{'nifi.registry.jdk.home':env['CFM_JAVA_HOME'], 'bootstrap safety valve':'registry-bootstrap.xml',
                        'nifi-registry.properties safety valve':'registry-properties.xml',
                        'JDBC URL':env['REGISTRY_DB_JDBC_URL'], 'JDBC driver':'org.postgresql.Driver',
                        'JDBC driver directory':env['POSTGRES_JDBC_DIR'], 'database user':env['REG_DB_USER'],
                        'Initial Admin Identity':env['REGISTRY_INITIAL_ADMIN_IDENTITY'],
                        'database password source':'REG_DB_PASS in EXPORTS'},
        'Reports Manager':{'database host':env['DB_HOST'], 'database port':env['DB_PORT'],
                           'database':env['RM_DB_NAME'], 'database user':env['RM_DB_USER'],
                           'TLS required':True, 'verify server certificate':True,
                           'CA PEM':env['DB_CLIENT_CA_FILE']},
        'instructions':['Apply to every applicable role configuration group, not just one node.',
                        'Keep existing non-FIPS properties; resolve duplicate java.arg names before saving.',
                        'Use the actual CM-issued truststore path and password on each host.',
                        'Configure Reports Manager TLS before starting the Management Service.',
                        'Enter full unmapped certificate DNs for certificate admin/node identities; the service also applies configured identity mappings to those values.',
                        'Use the certificate-derived node DN template and node-identities.json; do not append an arbitrary OU suffix.',
                        'Do not delete users.xml or authorizations.xml on a deployed service to resolve an identity conflict.',
                        'Never change the sensitive-properties key on an existing flow without a planned re-encryption migration.']}
    nifi={'nifi.sensitive.props.algorithm':env['NIFI_SENSITIVE_PROPS_ALGORITHM'],
          'nifi.sensitive.props.key':env['NIFI_SENSITIVE_PROPS_KEY'],
          'nifi.security.keystoreType':'BCFKS','nifi.security.truststoreType':'BCFKS',
          'nifi.web.http.port':'','nifi.web.https.port':env['NIFI_HTTPS_PORT'],
          'nifi.python.command':env['NIFI_PYTHON_BIN'],
          'nifi.security.allow.anonymous.authentication':'false',
          'nifi.autogen.node.identities':'true',
          'nifi.autogen.node.identities.dn.prefix':env['NIFI_NODE_DN_PREFIX'],
          'nifi.autogen.node.identities.dn.suffix':env['NIFI_NODE_DN_SUFFIX']}
    registry={'nifi.registry.security.keystoreType':'BCFKS','nifi.registry.security.truststoreType':'BCFKS',
              'nifi.registry.security.keymanager.algorithm':'PKIX','nifi.registry.security.trustmanager.algorithm':'PKIX',
              'nifi.registry.web.http.port':'','nifi.registry.web.https.port':env['NIFI_REGISTRY_HTTPS_PORT']}
    return {'nifi-bootstrap.xml':properties(opts),'registry-bootstrap.xml':properties(opts),
            'nifi-properties.xml':properties(nifi),'registry-properties.xml':properties(registry),
            'nifi-environment.txt':'HADOOP_SASL_MECHANISM=DIGEST-SHA\n',
            'service-settings.json':json.dumps(settings,indent=2)+'\n'}


if __name__=='__main__':
    os.umask(0o077)
    target=Path(os.environ['CFM_GENERATED_CONFIG_DIR']); target.mkdir(parents=True,exist_ok=True);target.chmod(0o700)
    for name,content in render(os.environ).items():
        path=target/name;path.write_text(content);path.chmod(0o600)
