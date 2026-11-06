"""Regressions for an HTTP-only core that works without the optional TLS folder."""
import functools
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
import xml.etree.ElementTree as ET

from test_profile import ROOT,config,module
from test_rhel98 import Host,jar_bytes
import prepare_artifacts as artifacts


class HttpInstallTests(unittest.TestCase):
    def test_core_configuration_has_no_certificate_or_optional_tls_inputs(self):
        env=config()
        self.assertFalse(any(name.startswith('AUTO_TLS_') for name in env))
        for name in ('DB_CLIENT_CA_FILE','POSTGRES_TLS_SOURCE_CERT','NIFI_INITIAL_ADMIN_IDENTITY'):
            self.assertNotIn(name,env)
        self.assertEqual(env['DB_SSLMODE'],'disable')
        self.assertEqual(env['CM_RUNTIME_PORT'],'7180')
        self.assertIn('sslmode=disable',env['CM_DB_JDBC_URL'])
        self.assertIn('sslmode=disable',env['REGISTRY_DB_JDBC_URL'])

    def test_agent_general_section_disables_tls_without_changing_other_sections(self):
        helper=module('configure_agent')
        original='[Other]\nserver_host=keep.example\nuse_tls=1\n[General]\n# keep comment\nserver_host=old.example\nuse_tls=1\n[Last]\ncustom=keep\n'
        updated=helper.configure(original,'cm.example.test','7182')
        self.assertIn('[Other]\nserver_host=keep.example\nuse_tls=1',updated)
        self.assertIn('[General]\n# keep comment\nserver_host=cm.example.test\nuse_tls=0\nserver_port=7182\n',updated)
        self.assertIn('[Last]\ncustom=keep',updated)
        self.assertEqual(helper.configure(updated,'cm.example.test','7182'),updated)

    @unittest.skipUnless(os.geteuid()==0,'Runs root-gated core scripts in an isolated host')
    def test_real_preflight_and_configuration_run_with_no_tls_folder(self):
        with tempfile.TemporaryDirectory() as tmp:
            host=Host(tmp);copy=host.root/'core-only';shutil.copytree(ROOT,copy,ignore=shutil.ignore_patterns('__pycache__'))
            host.kit_root=copy
            self.assertFalse((copy.parent/'TLS').exists())
            host.env.update(MANAGER_HOST='cm.fixture.test',AGENT_HOST='worker.fixture.test',DB_HOST='cm.fixture.test',
                            CFM_GENERATED_CONFIG_DIR=str(host.root/'generated'))
            # Fresh hosts have neither JDK. Preflight must not require either
            # installed homes or administrator-supplied Java archives/checksums.
            for key in ('JAVA_HOME_TARGET','CFM_JAVA_HOME'):
                host.env[key]=str(host.root/key)
                self.assertFalse(Path(host.env[key]).exists())
            host.env.update(JAVA_ARCHIVE_FILE=str(host.root/'not-staged-17.tar.gz'),
                            JAVA_ARCHIVE_SHA256='',CFM_JAVA_ARCHIVE_FILE=str(host.root/'not-staged-21.tar.gz'),
                            CFM_JAVA_ARCHIVE_SHA256='')
            host.fake_binary('getent','echo "10.0.0.1 STREAM fixture"')
            for command in ('curl','dnf','nc','ping','timedatectl','chronyc'):
                host.fake_binary(command,'exit 0')
            host.fake_binary('systemctl','exit 0')
            for role,name in (('manager','cm.fixture.test'),('agent','worker.fixture.test')):
                host.fake_binary('hostname', 'case "$1" in -f) echo '+name+';; -I) echo 10.0.0.1;; *) echo fixture;; esac')
                result=host.run('00_check_connectivity.sh',role)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertNotIn('ca-chain.pem',result.stdout)
            artifacts.prepare(host.env,host)
            result=host.run('16_generate_cfm_fips_config.sh')
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            props=Path(host.env['CFM_GENERATED_CONFIG_DIR'])/'nifi-properties.xml'
            self.assertIn('nifi.web.http.port',props.read_text())
            self.assertNotIn('trustStore=',(props.parent/'nifi-bootstrap.xml').read_text())
            settings=json.loads((props.parent/'service-settings.json').read_text())
            self.assertFalse(settings['CDP Runtime']['Enable TLS/SSL'])

    @unittest.skipUnless(os.geteuid()==0,'Runs real database prepare wrapper with isolated vendor commands')
    def test_cm_database_prepare_passes_non_ssl_url_and_no_ssl_switch(self):
        with tempfile.TemporaryDirectory() as tmp:
            host=Host(tmp);home=host.root/'jdk';(home/'bin').mkdir(parents=True)
            for name in ('java','jar','keytool'):
                p=home/'bin'/name;p.write_text('#!/bin/sh\necho \'openjdk version "17.0.13"\' >&2\n');p.chmod(0o755)
            args=host.root/'prepare-args';prep=host.root/'scm_prepare_database.sh'
            prep.write_text('#!/usr/bin/env bash\nIFS= read -r pass\n[[ "$pass" == "$CM_DB_PASS" ]] || exit 1\nprintf "%s\\n" "$@" > "'+str(args)+'"\necho "Vendor logged $pass"\n');prep.chmod(0o755)
            driver=host.root/'jdbc/postgresql.jar';driver.parent.mkdir();driver.write_bytes(jar_bytes(['org/postgresql/Driver.class']))
            host.fake_binary('dnf','exit 0')
            host.fake_binary('rpm','if [[ "$1" == -E ]]; then echo 9; else echo "'+str(driver)+'"; fi')
            host.env.update(JAVA_HOME_TARGET=str(home),DB_HOST='cm.fixture.test',CM_PREP_DATABASE_SCRIPT=str(prep),
                            POSTGRES_JDBC_DIR=str(driver.parent),POSTGRES_JDBC_LINK=str(driver.parent/'postgresql-connector-java.jar'),
                            CM_DB_JDBC_URL='jdbc:postgresql://cm.fixture.test:5432/scm?sslmode=disable')
            result=host.run('11_prepare_cm_database.sh')
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            passed=args.read_text().splitlines()
            self.assertIn(host.env['CM_DB_JDBC_URL'],passed)
            self.assertNotIn('--ssl',passed);self.assertNotIn('-s',passed)
            self.assertNotIn(host.env['CM_DB_PASS'],result.stdout)
            self.assertIn('[REDACTED]',result.stdout)

    def test_live_validator_uses_http_and_no_certificate_files_for_both_roles(self):
        import validate_runtime
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200);self.end_headers();self.wfile.write(b'fixture UI')
            def log_message(self,*args):pass
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        self.addCleanup(server.server_close);self.addCleanup(server.shutdown)
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);env=config();env.update(CM_AGENT_PROCESS_DIR=str(root/'process'),PROC_ROOT=str(root/'proc'),
                                                CFM_JAVA_HOME=str(root/'jdk'),AGENT_HOST='127.0.0.1')
            (root/'jdk/bin').mkdir(parents=True);(root/'jdk/bin/java').write_text('fixture java')
            rendered=module('render_cfm_config').render(env)
            for index,role in enumerate(('nifi','registry'),1):
                prefix='nifi.' if role=='nifi' else 'nifi.registry.'
                role_dir=root/'process'/('100-NIFI_NODE' if role=='nifi' else '200-NIFI_REGISTRY');role_dir.mkdir(parents=True)
                xml=rendered['nifi-properties.xml' if role=='nifi' else 'registry-properties.xml']
                props={p.findtext('name'):p.findtext('value') or '' for p in ET.fromstring('<configuration>'+xml+'</configuration>')}
                props[prefix+'web.http.host']='127.0.0.1';props[prefix+'web.http.port']=str(server.server_port)
                (role_dir/('nifi.properties' if role=='nifi' else 'nifi-registry.properties')).write_text('\n'.join(k+'='+v for k,v in props.items()))
                xml=rendered['nifi-bootstrap.xml' if role=='nifi' else 'registry-bootstrap.xml']
                boot={p.findtext('name'):p.findtext('value') for p in ET.fromstring('<configuration>'+xml+'</configuration>')}
                (role_dir/'bootstrap.conf').write_text('\n'.join(k+'='+v for k,v in boot.items()))
                pid=root/'proc'/str(index);pid.mkdir(parents=True)
                main=b'org.apache.nifi.NiFi' if role=='nifi' else b'org.apache.nifi.registry.NiFiRegistry'
                (pid/'cmdline').write_bytes(main+b'\0'+b' '.join(v.encode() for v in boot.values()))
                (pid/'environ').write_bytes(b'HADOOP_SASL_MECHANISM=DIGEST-SHA\0')
                (pid/'exe').symlink_to(root/'jdk/bin/java')
                validate_runtime.check_runtime(role,env)

    def test_http_validator_rejects_redirect_to_https(self):
        from urllib.request import Request
        import validate_runtime
        with self.assertRaisesRegex(ValueError,'non-HTTP'):
            validate_runtime.HttpOnlyRedirect().redirect_request(Request('http://localhost/nifi/'),None,302,'redirect',{},'https://localhost/nifi/')


if __name__=='__main__':unittest.main()
