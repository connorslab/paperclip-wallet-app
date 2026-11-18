"""Relocated frozen Windows Jars: verified loopback TLS and owned child lifetime."""
import argparse
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import time
import unittest
from urllib.request import HTTPSHandler, ProxyHandler, build_opener

from pipe_io import read_available
from windows.private_storage import read_private_file

BUNDLE = None


class FrozenJars(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.bundle=self.root/'relocated app'
        shutil.copytree(BUNDLE,self.bundle)
        self.data=self.root/'private jars';self.children=[]
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for child in self.children:
            if child.poll() is None:child.kill()
            child.wait(timeout=10)
            for stream in (child.stdin,child.stdout,child.stderr):
                if stream:stream.close()

    def launch(self):
        child=subprocess.Popen([str(self.bundle/'PaperclipJars.exe'),'--data-dir',str(self.data)],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,creationflags=subprocess.CREATE_NO_WINDOW,
            cwd=self.root,env={**os.environ,'PYTHONPATH':'Z:/must-not-load','JOINMARKET_DATA_DIR':'Z:/must-not-use',
            'JMWALLETD_NO_TLS':'1','HTTPS_PROXY':'http://127.0.0.1:1'})
        self.children.append(child);return child

    def ready(self,child):
        value=b'';deadline=time.monotonic()+45
        while b'\n' not in value and time.monotonic()<deadline:
            chunk=read_available(child.stdout.fileno(),1024,.1)
            if chunk:value+=chunk
            elif child.poll() is not None:break
        self.assertTrue(value,'Frozen Jars exited or timed out before readiness; no exception details or secrets collected')
        result=json.loads(value);self.assertEqual(set(result),{'ready','endpoint'});self.assertTrue(result['ready'])
        self.assertTrue(result['endpoint'].startswith('https://127.0.0.1:'))
        with read_private_file(self.data/'ssl/cert.pem') as file:cert=file.read()
        context=ssl.create_default_context(cadata=cert.decode('ascii'))
        opener=build_opener(ProxyHandler({}),HTTPSHandler(context=context))
        with opener.open(result['endpoint']+'/api/v1/paperclip/capabilities',timeout=5) as response:
            self.assertEqual(json.load(response)['version'],2)
        return cert

    def test_verified_tls_duplicate_child_restart_and_identity(self):
        child=self.launch();cert=self.ready(child)
        other=self.launch();self.assertNotEqual(other.wait(timeout=20),0)
        self.assertIsNone(child.poll())
        child.stdin.close();self.assertEqual(child.wait(timeout=30),0)
        resumed=self.launch();self.assertEqual(self.ready(resumed),cert)
        resumed.stdin.close();self.assertEqual(resumed.wait(timeout=30),0)

    def test_crash_releases_ownership_and_preserves_tls(self):
        child=self.launch();cert=self.ready(child);child.kill();child.wait(timeout=10)
        resumed=self.launch();self.assertEqual(self.ready(resumed),cert)
        resumed.stdin.close();self.assertEqual(resumed.wait(timeout=30),0)


if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--bundle',type=Path,required=True)
    args,remaining=parser.parse_known_args();BUNDLE=args.bundle.resolve(strict=True)
    unittest.main(argv=[__file__]+remaining)
