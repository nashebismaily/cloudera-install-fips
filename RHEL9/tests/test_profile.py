"""Offline regression tests; these do not certify RHEL or proprietary cryptographic modules."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
import re

ROOT=Path(__file__).resolve().parents[1]

def module(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'lib'/(name+'.py'))
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value

def config():
    result=subprocess.run(['bash','-c','set -a; source "$1"; env -0','bash',str(ROOT/'EXPORTS')],capture_output=True,check=True)
    names=set(re.findall(r'^export ([A-Za-z_][A-Za-z0-9_]*)=',(ROOT/'EXPORTS').read_text(),re.M))
    return dict(item.split('=',1) for item in result.stdout.decode().split('\0') if '=' in item and item.split('=',1)[0] in names)

class ProfileTests(unittest.TestCase):
    def test_current_profile_and_independent_jdks(self):
        env=config()
        self.assertEqual((env['EXPECTED_RHEL_MAJOR'],env['EXPECTED_RHEL_MINOR']),('9','8'))
        self.assertEqual(env['CM_VERSION'],'7.13.2.10000')
        self.assertEqual((env['CFM_VERSION'],env['CFM_BUILD'],env['NIFI_VERSION']),('4.12.0.10001','','2.6.0'))
        self.assertEqual(env['CDP_RUNTIME_VERSION'],'7.3.2.10000')
        self.assertEqual((env['JAVA_MAJOR'],env['CFM_JAVA_MAJOR']),('17','21'))
        self.assertNotEqual(env['JAVA_HOME_TARGET'],env['CFM_JAVA_HOME'])
        self.assertTrue(env['CFM_MANIFEST_URL'].endswith('/cfm4/4.12.0.10001/redhat9/yum/tars/parcel/manifest.json'))
        self.assertEqual(env['CM_AGENT_PYTHON_EXPECTED_VERSION'],'Python 3.11')
        self.assertEqual(env['AUTO_TLS_STORE_TYPE'],'BCFKS')
        for name in ('CM_DB_PASS','RM_DB_PASS','REG_DB_PASS','HUE_DB_PASS','HIVE_DB_PASS','RANGER_DB_PASS',
                     'AUTO_TLS_HOST_KEY_PASSWORD','AUTO_TLS_KEYSTORE_PASSWORD','AUTO_TLS_TRUSTSTORE_PASSWORD'):
            self.assertGreaterEqual(len(env[name]),14,name)

    def test_provider_patch_is_idempotent_and_preserves_other_settings(self):
        helper=module('java_fips');env=config();env['FIPS_SASL_JAR']='sasl-test.jar'
        with tempfile.TemporaryDirectory() as tmp:
            for name in ('jdk17','jdk21'):
                home=Path(tmp)/name;security=home/'conf/security';security.mkdir(parents=True)
                (security/'java.security').write_text('security.provider.1=OldProvider\nkeystore.type=jks\ncustom.setting=keep\n')
                (security/'java.policy').write_text('grant { permission java.lang.RuntimePermission "original"; };\n')
                helper.configure(home,env)
                before={p.name:p.read_text() for p in security.iterdir() if not '.bak.' in p.name}
                helper.configure(home,env)
                self.assertEqual(before,{p.name:p.read_text() for p in security.iterdir() if not '.bak.' in p.name})
                text=(security/'java.security').read_text()
                self.assertIn('custom.setting=keep',text)
                self.assertIn('security.provider.3=com.cloudera.security.sasl.ClouderaSaslProvider',text)
                self.assertEqual(text.count('keystore.type=BCFKS'),1)
                self.assertNotIn('\nsecurity.provider.1=OldProvider',text)

    def test_bundle_rejects_wrong_hash_and_missing_provider_class(self):
        helper=module('fips_artifacts')
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);names=['ccj-4.0.0-fips.jar','bctls-2.0.17.1.jar','bcutil.jar','sasl-sha256aes-test.jar']
            classes=['com/safelogic/cryptocomply/jcajce/provider/CryptoComplyFipsProvider.class',
                     'org/bouncycastle/jsse/provider/BouncyCastleJsseProvider.class','utility.class',
                     'com/cloudera/security/sasl/ClouderaSaslProvider.class']
            for name,cls in zip(names,classes):
                with zipfile.ZipFile(root/name,'w') as jar: jar.writestr(cls,b'fixture')
            sums=root/'SHA256SUMS'
            sums.write_text(''.join(hashlib.sha256((root/name).read_bytes()).hexdigest()+'  '+name+'\n' for name in names))
            helper.validate_bundle(root,names,sums)
            with (root/names[0]).open('ab') as handle: handle.write(b'tamper')
            with self.assertRaises(ValueError): helper.validate_bundle(root,names,sums)
            with zipfile.ZipFile(root/names[0],'w') as jar: jar.writestr('wrong.class',b'fixture')
            with self.assertRaises(ValueError): helper.validate_bundle(root,names,sums,False)

    def test_generated_settings_include_every_fips_layer_and_escape_xml(self):
        helper=module('render_cfm_config');env=config();env['NIFI_TRUSTSTORE_PASSWORD']='Sample<Trust&Password2026'
        files=helper.render(env)
        for name in ('nifi-bootstrap.xml','registry-bootstrap.xml'):
            root=ET.fromstring('<configuration>'+files[name]+'</configuration>')
            properties={p.findtext('name'):p.findtext('value') for p in root}
            values=' '.join(properties.values())
            self.assertIn('--add-modules=ALL-MODULE-PATH',values)
            self.assertIn('allowGCMCiphers=true',values)
            self.assertIn('trustStoreType=BCFKS',values)
            self.assertIn(env['NIFI_TRUSTSTORE_PASSWORD'],values)
        nifi=ET.fromstring('<configuration>'+files['nifi-properties.xml']+'</configuration>')
        self.assertIn(env['NIFI_SENSITIVE_PROPS_ALGORITHM'],[p.findtext('value') for p in nifi])
        self.assertIn('DIGEST-SHA',files['nifi-environment.txt'])
        settings=json.loads(files['service-settings.json'])
        self.assertEqual(settings['NiFi']['nifi.jdk.home'],env['CFM_JAVA_HOME'])
        self.assertIn('sslmode=verify-full',settings['NiFi Registry']['JDBC URL'])

    def test_service_detection_adds_systemd_suffix(self):
        with tempfile.TemporaryDirectory() as tmp:
            systemctl=Path(tmp)/'systemctl'
            systemctl.write_text('#!/bin/sh\nprintf "%s enabled\\n" "$4"\n');systemctl.chmod(0o755)
            env=dict(os.environ,PATH=tmp+os.pathsep+os.environ['PATH'])
            result=subprocess.run(['bash','-c','source "$1"; service_exists cloudera-scm-agent','bash',str(ROOT/'lib/common.sh')],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)


    def test_runtime_validation_rejects_http_and_wrong_store_type(self):
        helper=module('validate_runtime');env=config()
        properties={'nifi.web.https.port':'8443', 'nifi.web.http.port':'',
                    'nifi.security.keystoreType':'BCFKS','nifi.security.truststoreType':'BCFKS',
                    'nifi.sensitive.props.algorithm':env['NIFI_SENSITIVE_PROPS_ALGORITHM'],
                    'nifi.sensitive.props.key':'FixtureSensitiveKey2026'}
        bootstrap={'java.arg.fixture':'--module-path='+env['JAVA_FIPS_DIR']+' --add-modules=ALL-MODULE-PATH --add-exports=fixture -Dcom.safelogic.cryptocomply.fips.approved_only=true -Dorg.bouncycastle.fips.approved_only=true -DallowGCMCiphers=true -DtrustStoreType=BCFKS'}
        helper.inspect_properties('nifi',properties,bootstrap,env)
        properties['nifi.web.http.port']='8080'
        with self.assertRaises(ValueError): helper.inspect_properties('nifi',properties,bootstrap,env)
        properties['nifi.web.http.port']='';properties['nifi.security.keystoreType']='JKS'
        with self.assertRaises(ValueError): helper.inspect_properties('nifi',properties,bootstrap,env)

    @unittest.skipUnless(os.geteuid()==0,'File ownership is set by the real CM configuration helper')
    def test_cm_defaults_keep_fips_sasl_bcutil_and_database_trust_on_rerun(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);defaults=root/'cm-defaults';defaults.write_text('export EXISTING=keep\n')
            trust=root/'db.bcfks';trust.write_text('fixture')
            script='source "$1/lib/common.sh"\nCM_SERVER_DEFAULTS_FILE="$2/cm-defaults"\nCM_AGENT_SYSTEMD_FIPS_DIR="$2/agent"\nCM_AGENT_SYSTEMD_FIPS_FILE="$2/agent/fips.conf"\nCM_SUPERVISORD_SYSTEMD_FIPS_DIR="$2/supervisor"\nCM_SUPERVISORD_SYSTEMD_FIPS_FILE="$2/supervisor/fips.conf"\nDB_JAVA_TRUSTSTORE="$2/db.bcfks"\nCLOUDERA_SERVICE_GROUP="$(id -g)"\nconfigure_cm_server_fips_opts\nconfigure_cm_server_fips_opts\n'
            result=subprocess.run(['bash','-e','-c',script,'bash',str(ROOT),str(root)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            text=defaults.read_text()
            self.assertIn('EXISTING=keep',text)
            self.assertIn('com.cloudera.cmf.fipsSaslMode=true',text)
            self.assertIn('CMF_ADD_TO_CLASSPATH',text)
            self.assertIn('bcutil',text)
            self.assertIn('javax.net.ssl.trustStoreType=BCFKS',text)
            self.assertEqual(text.count('# BEGIN MANAGED RHEL9 FIPS'),1)
            self.assertEqual(text.count('javax.net.ssl.trustStorePassword='),1)
            self.assertEqual(len(list(root.glob('cm-defaults.bak.*'))),1)

    def test_runtime_trust_preserves_vendor_roots_and_deduplicates_explicit_cas(self):
        import re
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cert=root/'ca.pem';key=root/'ca.key'
            result=subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','2',
                '-subj','/CN=Offline Trust Input Fixture','-addext','basicConstraints=critical,CA:TRUE',
                '-keyout',str(key),'-out',str(cert)],capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr.decode())
            env=dict(os.environ,JAVA_TRUST_INCLUDE_VENDOR_CACERTS='true',JAVA_CACERTS_FILE='',JAVA_CACERTS_PASSWORD='changeit')
            command=['java',str(ROOT/'lib/TruststoreTool.java'),'--inspect-inputs']
            def count(files):
                result=subprocess.run(command+files,env=env,capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)
                return int(re.search(r'contains (\d+) unique',result.stdout).group(1))
            vendor=count([]);self.assertGreater(vendor,0)
            self.assertEqual(count([str(cert),str(cert)]),vendor+1)

    def test_manager_preflight_requires_server_key_but_agent_does_not(self):
        import shlex
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);staged=root/'input';staged.write_text('fixture')
            java=root/'jdk/bin';java.mkdir(parents=True);(java/'java').write_text('#!/bin/sh\n');(java/'java').chmod(0o755)
            code='source "$1/lib/common.sh"\n'
            override={'CLOUDERA_REPO_USER':'fixture','CLOUDERA_REPO_PASS':'fixture','MANAGER_HOST':'cm.example.test',
                      'FIPS_JAR_SOURCE_DIR':root,'FIPS_CCJ_JAR':'input','FIPS_BCTLS_JAR':'input','FIPS_BCUTIL_JAR':'input',
                      'FIPS_CHECKSUM_FILE':staged,'DB_CLIENT_CA_FILE':staged,'JAVA_HOME_TARGET':java.parent,
                      'CFM_JAVA_HOME':java.parent,'POSTGRES_TLS_SOURCE_CERT':root/'missing.crt','POSTGRES_TLS_SOURCE_KEY':root/'missing.key'}
            code+=''.join(name+'='+shlex.quote(str(value))+'\n' for name,value in override.items())
            agent=subprocess.run(['bash','-e','-c',code+'validate_install_inputs agent','bash',str(ROOT)],capture_output=True,text=True)
            self.assertEqual(agent.returncode,0,agent.stdout+agent.stderr)
            manager=subprocess.run(['bash','-e','-c',code+'validate_install_inputs manager','bash',str(ROOT)],capture_output=True,text=True)
            self.assertNotEqual(manager.returncode,0)
            self.assertIn('PostgreSQL TLS material',manager.stdout)

if __name__=='__main__': unittest.main()
