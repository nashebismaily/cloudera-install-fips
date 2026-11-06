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
        self.assertEqual(env['DB_SSLMODE'],'disable')
        self.assertEqual(env['CM_RUNTIME_PROTOCOL'],'http')
        self.assertEqual(env['CM_RUNTIME_PORT'],'7180')
        for name in ('CM_DB_PASS','RM_DB_PASS','REG_DB_PASS','HUE_DB_PASS','HIVE_DB_PASS','RANGER_DB_PASS',
                     'NIFI_SENSITIVE_PROPS_KEY'):
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

    def test_generated_settings_are_http_only_and_keep_fips_encryption(self):
        helper=module('render_cfm_config');env=config();env['NIFI_SENSITIVE_PROPS_KEY']='Sample<Key&Password2026'
        files=helper.render(env)
        for name in ('nifi-bootstrap.xml','registry-bootstrap.xml'):
            root=ET.fromstring('<configuration>'+files[name]+'</configuration>')
            values=' '.join(p.findtext('value') or '' for p in root)
            self.assertIn('--add-modules=ALL-MODULE-PATH',values)
            self.assertIn('approved_only=true',values)
            self.assertNotIn('trustStore',values)
            self.assertNotIn('keyStore',values)
        nifi=ET.fromstring('<configuration>'+files['nifi-properties.xml']+'</configuration>')
        props={p.findtext('name'):p.findtext('value') or '' for p in nifi}
        self.assertEqual(props['nifi.web.http.port'],'8080')
        self.assertEqual(props['nifi.web.https.port'],'')
        self.assertEqual(props['nifi.security.keystore'],'')
        self.assertEqual(props['nifi.sensitive.props.key'],env['NIFI_SENSITIVE_PROPS_KEY'])
        self.assertIn('DIGEST-SHA',files['nifi-environment.txt'])
        settings=json.loads(files['service-settings.json'])
        self.assertEqual(settings['NiFi']['nifi.jdk.home'],env['CFM_JAVA_HOME'])
        self.assertIn('sslmode=disable',settings['NiFi Registry']['JDBC URL'])
        self.assertFalse(settings['Cloudera Manager']['web_tls'])
        self.assertFalse(settings['Reports Manager']['Use SSL'])

    def test_service_detection_adds_systemd_suffix(self):
        with tempfile.TemporaryDirectory() as tmp:
            systemctl=Path(tmp)/'systemctl'
            systemctl.write_text('#!/bin/sh\nprintf "%s enabled\\n" "$4"\n');systemctl.chmod(0o755)
            env=dict(os.environ,PATH=tmp+os.pathsep+os.environ['PATH'])
            result=subprocess.run(['bash','-c','source "$1"; service_exists cloudera-scm-agent','bash',str(ROOT/'lib/common.sh')],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)


    def test_runtime_validation_accepts_http_and_rejects_https_or_missing_fips(self):
        helper=module('validate_runtime');env=config()
        rendered=module('render_cfm_config').render(env)
        def props(name):
            return {p.findtext('name'):p.findtext('value') or '' for p in ET.fromstring('<configuration>'+rendered[name]+'</configuration>')}
        settings=props('nifi-properties.xml');bootstrap=props('nifi-bootstrap.xml')
        helper.inspect_properties('nifi',settings,bootstrap,env)
        settings['nifi.web.https.port']='8443'
        with self.assertRaisesRegex(ValueError,'HTTPS'):helper.inspect_properties('nifi',settings,bootstrap,env)
        settings['nifi.web.https.port']='';settings['nifi.security.keystore']='/absent/server.bcfks'
        with self.assertRaisesRegex(ValueError,'certificate store'):helper.inspect_properties('nifi',settings,bootstrap,env)
        settings['nifi.security.keystore']=''
        with self.assertRaises(ValueError):helper.inspect_properties('nifi',settings,{},env)

    @unittest.skipUnless(os.geteuid()==0,'File ownership is set by the real CM configuration helper')
    def test_cm_defaults_keep_fips_sasl_bcutil_and_public_roots_on_rerun(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);defaults=root/'cm-defaults';defaults.write_text('export EXISTING=keep\n')
            trust=root/'db.bcfks';trust.write_text('fixture')
            script='source "$1/lib/common.sh"\nCM_SERVER_DEFAULTS_FILE="$2/cm-defaults"\nCM_AGENT_SYSTEMD_FIPS_DIR="$2/agent"\nCM_AGENT_SYSTEMD_FIPS_FILE="$2/agent/fips.conf"\nCM_SUPERVISORD_SYSTEMD_FIPS_DIR="$2/supervisor"\nCM_SUPERVISORD_SYSTEMD_FIPS_FILE="$2/supervisor/fips.conf"\nJAVA_PUBLIC_TRUSTSTORE="$2/db.bcfks"\nCLOUDERA_SERVICE_GROUP="$(id -g)"\nconfigure_cm_server_fips_opts\nconfigure_cm_server_fips_opts\n'
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

    def test_public_roots_need_no_customer_certificates(self):
        env=dict(os.environ,JAVA_TRUST_INCLUDE_VENDOR_CACERTS='true',JAVA_CACERTS_FILE='',JAVA_CACERTS_PASSWORD='changeit')
        result=subprocess.run(['java',str(ROOT/'lib/TruststoreTool.java'),'--inspect-inputs'],env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertGreater(int(re.search(r'contains (\d+) unique',result.stdout).group(1)),0)

    def test_manager_and_agent_preflight_need_no_ca_or_server_key(self):
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
            self.assertEqual(manager.returncode,0,manager.stdout+manager.stderr)

if __name__=='__main__': unittest.main()
