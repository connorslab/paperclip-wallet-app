import base64
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import shutil
import subprocess
import sys
import threading
import time
import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('startos_rpc', Path(__file__).with_name('startos-rpc-entry.py'))
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)


class StartOSCredentialTests(unittest.TestCase):
    def test_atomic_node_rotation_and_missing_cookie_fail_closed(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            source, target = root / 'node', root / 'copy'
            source.write_bytes(b'fixture:first\n')
            rpc.refresh_cookie(source, target, owner=None)
            self.assertEqual(target.read_bytes(), b'fixture:first\n')
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o400)
            unchanged = target.stat().st_ino
            rpc.refresh_cookie(source, target, owner=None)
            self.assertEqual(target.stat().st_ino, unchanged)
            replacement = root / 'new-node'
            replacement.write_bytes(b'fixture:rotated\n')
            replacement.replace(source)
            rpc.refresh_cookie(source, target, owner=None)
            self.assertEqual(target.read_bytes(), b'fixture:rotated\n')
            source.unlink()
            with self.assertRaises(FileNotFoundError):
                rpc.refresh_cookie(source, target, owner=None)

    def test_bad_credential_sources_are_rejected_without_replacing_copy(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            source, target = root / 'node', root / 'copy'
            target.write_bytes(b'fixture:old\n')
            for invalid in (b'', b':secret', b'user:', b'no-colon', b'user:space inside', b'u:' + b'x' * 4096):
                source.write_bytes(invalid)
                with self.assertRaises(ValueError):
                    rpc.refresh_cookie(source, target, owner=None)
                self.assertEqual(target.read_bytes(), b'fixture:old\n')
            source.unlink()
            source.symlink_to(target)
            with self.assertRaises(OSError):
                rpc.read_cookie(source)
            source.unlink()
            os.mkfifo(source)
            with self.assertRaises(ValueError):
                rpc.read_cookie(source)

    def test_failed_replace_preserves_previous_cookie_and_cleans_temporary(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            target = root / 'copy'
            target.write_bytes(b'fixture:old\n')
            with patch.object(rpc.os, 'replace', side_effect=OSError('synthetic fault')):
                with self.assertRaises(OSError):
                    rpc.write_cookie(target, b'fixture:new', None, 0o400)
            self.assertEqual(target.read_bytes(), b'fixture:old\n')
            self.assertEqual(list(root.iterdir()), [target])

    def test_listener_is_loopback_enforced_and_does_not_inherit_secrets(self):
        with patch.dict(os.environ, {'UNRELATED_SECRET': 'not-forwarded'}):
            env = rpc.filter_environment('http://10.0.0.8:18443')
        self.assertNotIn('UNRELATED_SECRET', env)
        self.assertEqual(env['JM_RPC_FILTER_MODE'], 'enforce')
        self.assertEqual(env['JM_RPC_FILTER_LISTEN'], '127.0.0.1:28187')
        self.assertEqual(env['JM_RPC_FILTER_NODE_COOKIE'], '/private-rpc/node.cookie')
        for invalid in ('http://u:p@host:8332', 'http://host:0', 'http://host:70000',
                        'https://host:8332', 'http://host:8332/wallet/test', 'http://host:8332?x=1'):
            with self.assertRaises(ValueError):
                rpc.filter_environment(invalid)


@unittest.skipUnless(os.environ.get('PAPERCLIP_CONTAINER_TESTS') == '1' and os.geteuid() == 0,
                     'Requires the isolated Linux companion test container')
class StartOSProcessTests(unittest.TestCase):
    def test_unprivileged_listener_rotates_cookie_and_stops_with_supervisor(self):
        roots = [Path('/mnt/xbt-node'), Path('/private-rpc'), Path('/rpc-filter')]
        self.assertFalse(any(path.exists() for path in roots), 'Use a fresh test container')
        roots[0].mkdir(parents=True)
        cookie = roots[0] / '.cookie'
        cookie.write_bytes(b'fixture:first\n')
        expected = [b'fixture:first']

        class Node(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                self.rfile.read(int(self.headers['Content-Length']))
                valid = self.headers.get('Authorization') == 'Basic ' + base64.b64encode(expected[0]).decode()
                payload = json.dumps({'result': {'chain': 'main'}, 'error': None, 'id': 'fixture'}).encode()
                self.send_response(200 if valid else 401)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        node = ThreadingHTTPServer(('127.0.0.1', 0), Node)
        worker = threading.Thread(target=node.serve_forever, daemon=True)
        worker.start()
        supervisor = subprocess.Popen([sys.executable, str(Path(__file__).with_name('startos-rpc-entry.py'))],
            env={'PATH': os.environ['PATH'], 'PAPERCLIP_NODE_RPC_URL': f'http://127.0.0.1:{node.server_port}'},
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            def request():
                client = (roots[2] / 'client.cookie').read_bytes().strip()
                connection = http.client.HTTPConnection('127.0.0.1', 28187, timeout=2)
                try:
                    connection.request('POST', '/', json.dumps({'method': 'getblockchaininfo', 'params': [], 'id': 'fixture'}),
                        {'Authorization': 'Basic ' + base64.b64encode(client).decode(), 'Content-Type': 'application/json'})
                    response = connection.getresponse()
                    return response.status, json.loads(response.read())
                finally:
                    connection.close()

            def eventually(predicate):
                deadline = time.monotonic() + 12
                while time.monotonic() < deadline:
                    try:
                        if predicate():
                            return
                    except (OSError, ValueError):
                        pass
                    if supervisor.poll() is not None:
                        self.fail('Credential supervisor exited unexpectedly')
                    time.sleep(.1)
                self.fail('Credential supervisor did not become ready')

            eventually(lambda: request()[0] == 200)
            children = Path(f'/proc/{supervisor.pid}/task/{supervisor.pid}/children').read_text().split()
            self.assertEqual(len(children), 1)
            child = children[0]
            status = Path(f'/proc/{child}/status').read_text()
            self.assertRegex(status, r'Uid:\s+1001\s+1001\s+1001\s+1001')
            self.assertRegex(status, r'NoNewPrivs:\s+1')
            self.assertRegex(status, r'CapBnd:\s+0+\n')
            self.assertEqual((roots[2] / 'client.cookie').stat().st_gid, 1000)
            self.assertEqual(stat.S_IMODE((roots[2] / 'client.cookie').stat().st_mode), 0o440)
            self.assertNotIn('fixture:first', Path(f'/proc/{child}/environ').read_bytes().decode())
            expected[0] = b'fixture:rotated'
            replacement = roots[0] / 'rotated'
            replacement.write_bytes(expected[0] + b'\n')
            replacement.replace(cookie)
            eventually(lambda: request()[0] == 200 and rpc.read_cookie(roots[1] / 'node.cookie') == expected[0])
            supervisor.terminate()
            supervisor.wait(timeout=25)
            self.assertEqual(supervisor.returncode, 0)
            self.assertFalse(Path(f'/proc/{child}').exists(), 'Filter must not outlive its supervisor')
        finally:
            if supervisor.poll() is None:
                supervisor.terminate()
                supervisor.wait(timeout=25)
            supervisor.stderr.close()
            node.shutdown()
            node.server_close()
            worker.join(timeout=2)
            for path in roots:
                shutil.rmtree(path, ignore_errors=True)


if __name__ == '__main__':
    unittest.main()
