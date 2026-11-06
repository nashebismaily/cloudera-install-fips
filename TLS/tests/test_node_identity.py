import contextlib,io,json,os,shutil,subprocess,sys,tempfile,unittest,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'lib'))
import node_identity

def config():
    result=subprocess.run(['bash','-c','source "$1"; env -0','bash',str(ROOT/'EXPORTS')],capture_output=True,check=True)
    names=set(re.findall(r'^export ([A-Za-z_][A-Za-z0-9_]*)=',(ROOT/'EXPORTS').read_text(),re.M))
    return dict(item.split('=',1) for item in result.stdout.decode().split('\0') if '=' in item and item.split('=',1)[0] in names)

class NodeIdentityTests(unittest.TestCase):
    def test_node_dn_template_uses_actual_certificates_and_rejects_inconsistent_policy(self):
        self.assertEqual(node_identity.template({'nifi1.example': 'CN=nifi1.example', 'nifi2.example': 'CN=nifi2.example'}), ('CN=', ''))
        dns = {'nifi1.example': 'CN=nifi1.example,OU=Platform,O=Example',
               'nifi2.example': 'CN=nifi2.example,OU=Platform,O=Example'}
        self.assertEqual(node_identity.template(dns), ('CN=', ',OU=Platform,O=Example'))
        dns['nifi2.example'] = 'CN=nifi2.example,OU=Other,O=Example'
        with self.assertRaisesRegex(ValueError, 'one DN'):
            node_identity.template(dns)
        with self.assertRaisesRegex(ValueError, 'CN must match'):
            node_identity.template({'nifi1.example': 'CN=wrong.example'})

    def test_java_certificate_dn_roundtrip(self):
        import contextlib
        import shutil
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); cert = root / 'nifi1.example-cert.pem'
            result = subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','2',
                '-subj','/C=US/O=Example/OU=Platform/CN=nifi1.example','-keyout',str(root/'key.pem'),'-out',str(cert)],capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr.decode())
            inventory = root / 'hosts.csv'; inventory.write_text('host_id\nnifi1.example\n')
            env = config(); env.update(AUTO_TLS_HOSTS_CSV=str(inventory),AUTO_TLS_CERT_DIR=str(root),
                CM_AGENT_HOST_CERT_FILE=str(root/'absent'), NIFI_NODE_HOSTS='nifi1.example',
                JAVA_HOME_TARGET=str(Path(shutil.which('java')).resolve().parents[1]),AUTO_TLS_JAVA_OPTIONS='',
                CFM_GENERATED_CONFIG_DIR=str(root/'output'))
            with contextlib.redirect_stdout(io.StringIO()): node_identity.derive(env)
            actual=json.loads((root/'output/node-identities.json').read_text())
            self.assertEqual(actual['prefix'],'CN=')
            self.assertEqual(actual['suffix'],',OU=Platform,O=Example,C=US')
