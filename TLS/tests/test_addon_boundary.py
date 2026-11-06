"""The optional module configures installed hosts without importing the core tree."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class AddonBoundaryTests(unittest.TestCase):
    def test_optional_java_defaults_are_standalone_and_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);addon=root/'TLS';shutil.copytree(ROOT,addon,ignore=shutil.ignore_patterns('__pycache__'))
            self.assertFalse((root/'RHEL9').exists())
            (root/'fips').write_text('1\n')
            (root/'policy').write_text('#!/bin/sh\necho FIPS\n');(root/'policy').chmod(0o755)
            defaults=root/'cm-defaults';defaults.write_text('export CMF_JAVA_OPTS="-Dcom.cloudera.cmf.fipsMode=true"\n')
            profile=root/'tls-profile'
            override={'FIPS_KERNEL_FLAG_FILE':root/'fips','CRYPTO_POLICY_COMMAND':root/'policy',
                      'CM_SERVER_DEFAULTS_FILE':defaults,'CM_AGENT_SYSTEMD_TLS_DIR':root/'agent',
                      'CM_SUPERVISORD_SYSTEMD_TLS_DIR':root/'supervisor','DB_JAVA_TRUSTSTORE':root/'optional.bcfks'}
            profile.write_text('source '+shlex.quote(str(addon/'EXPORTS'))+'\n'+''.join(
                'export '+key+'='+shlex.quote(str(value))+'\n' for key,value in override.items()))
            env=dict(os.environ,AUTO_TLS_EXPORTS_FILE=str(profile))
            result=subprocess.run(['bash','-e','-c','source "$1/lib/common.sh"; configure_optional_tls_defaults; configure_optional_tls_defaults','bash',str(addon)],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            text=defaults.read_text()
            self.assertEqual(text.count('# BEGIN OPTIONAL TLS'),1)
            self.assertIn('com.cloudera.cmf.fipsMode=true',text)
            self.assertIn(str(root/'optional.bcfks'),text)
            for part in ('agent','supervisor'):
                content=(root/part/'optional-tls.conf').read_text()
                self.assertIn('approved_only=true',content)
                self.assertIn('allowGCMCiphers=true',content)
                self.assertIn(str(root/'optional.bcfks'),content)
