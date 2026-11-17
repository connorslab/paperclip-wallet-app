"""Unfunded desktop runner checks; run with --binary for real daemon lifecycle."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from managed_daemon import ManagedDaemon, NoRedirects, StartupError, default_data_root, local_endpoint
from urllib.request import Request, build_opener, ProxyHandler
from urllib.error import HTTPError
from urllib.parse import urlsplit

try:
    import fcntl
except ImportError:
    fcntl = None


BINARY = None


class RunnerPolicy(unittest.TestCase):
    def test_discovery_rejects_nonlocal_and_ambiguous_addresses(self):
        self.assertEqual(local_endpoint('http://127.0.0.1:1234'), 'http://127.0.0.1:1234')
        for address in ('http://example.com:1234', 'http://127.0.0.1:0',
                        'http://127.0.0.1:1234/path', 'http://user@127.0.0.1:1234',
                        'http://127.0.0.1:1234?token=synthetic', 'https://127.0.0.1:1234',
                        'http://127.0.0.1:65536', 'http://127.0.0.1:1234#secret',
                        'http://127.0.0.1:1234\n', 'http://localhost:1234'):
            with self.subTest(address=address), self.assertRaises(StartupError):
                local_endpoint(address)

    def test_data_locations_are_platform_specific(self):
        with patch('sys.platform', 'darwin'), patch.object(Path, 'home', return_value=Path('/test-home')):
            self.assertEqual(default_data_root(), Path('/test-home/Library/Application Support/Paperclip'))
        with patch('sys.platform', 'linux'), patch.dict(os.environ, {'XDG_DATA_HOME':'/test-data'}):
            self.assertEqual(default_data_root(), Path('/test-data/paperclip'))
        with patch('sys.platform', 'linux'), patch.dict(os.environ, {'XDG_DATA_HOME':'relative'}):
            with self.assertRaises(StartupError):
                default_data_root()
        with patch('sys.platform', 'win32'), self.assertRaises(StartupError):
            default_data_root()

    def test_authenticated_readiness_never_follows_redirect(self):
        calls = []

        class RedirectHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                calls.append(self.path)
                self.send_response(302)
                self.send_header('Location', '/credential-sink')
                self.end_headers()

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), RedirectHandler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            http = build_opener(ProxyHandler({}), NoRedirects())
            with self.assertRaises(StartupError):
                http.open(Request(f'http://127.0.0.1:{server.server_port}/ready',
                                  headers={'Authorization':'Bearer synthetic'}), timeout=2)
            self.assertEqual(calls, ['/ready'])
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)


@unittest.skipUnless(BINARY, 'Pass --binary for real daemon checks')
class RunnerLifecycle(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='paperclip-runner-qa-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'app'

    def runner(self, **kwargs):
        result = ManagedDaemon(BINARY, self.root, **kwargs)
        self.addCleanup(result.close)
        return result

    def test_owns_one_daemon_and_preserves_authentication_across_restart(self):
        first = self.runner()
        with patch.dict(os.environ, {'BARKD_BIND_HOST':'0.0.0.0', 'BARKD_BIND_PORT':'1',
                                    'BARKD_NO_UI':'true', 'BARKD_EXPOSE_MNEMONIC':'true',
                                    'HTTPS_PROXY':'http://127.0.0.1:1'}):
            endpoint = first.start()
        self.assertTrue(endpoint.startswith('http://127.0.0.1:'))
        token = (first.data / 'auth_token').read_bytes()
        http = build_opener(ProxyHandler({}), NoRedirects())
        with http.open(endpoint, timeout=2) as response:
            self.assertIn(b'id="jam-create"', response.read())
        with self.assertRaises(HTTPError) as denied:
            http.open(endpoint + '/api/v1/wallet', timeout=2)
        self.assertEqual(denied.exception.code, 401)
        with self.assertRaises(HTTPError) as mnemonic:
            http.open(Request(endpoint + '/api/v1/wallet/mnemonic',
                              headers={'Authorization':'Bearer ' + token.decode().strip()}), timeout=2)
        self.assertEqual(mnemonic.exception.code, 404)
        second = self.runner()
        with self.assertRaisesRegex(StartupError, 'already open'):
            second.start()
        self.assertIsNone(second.process)
        self.assertIsNone(first.process.poll())
        first.close()
        self.assertEqual(first.process.returncode, 0)
        third = self.runner()
        third.start()
        self.assertEqual((third.data / 'auth_token').read_bytes(), token)
        self.assertFalse((third.data / 'mnemonic').exists())
        third.close()
        self.assertEqual(third.process.returncode, 0)

    def test_refuses_loose_or_symlinked_storage_without_changing_it(self):
        self.root.mkdir(mode=0o755)
        with self.assertRaisesRegex(StartupError, 'private'):
            self.runner().start()
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o755)
        self.root.rmdir()
        target = Path(self.temporary.name) / 'target'
        target.mkdir(mode=0o700)
        self.root.symlink_to(target)
        with self.assertRaisesRegex(StartupError, 'private'):
            self.runner().start()
        self.assertEqual(list(target.iterdir()), [])

    def test_startup_error_does_not_rotate_authentication_or_leave_child(self):
        self.root.mkdir(mode=0o700)
        data = self.root / 'wallet'
        data.mkdir(mode=0o700)
        credential = data / 'auth_token'
        credential.write_text('synthetic-invalid-authentication')
        credential.chmod(0o600)
        runner = self.runner(startup_timeout=3)
        with self.assertRaises(StartupError):
            runner.start()
        self.assertIsNotNone(runner.process.poll())
        self.assertEqual(credential.read_text(), 'synthetic-invalid-authentication')
        self.assertFalse((data / 'mnemonic').exists())
        # Failure releases the launcher lock; do not alter the daemon secret.
        again = self.runner(startup_timeout=3)
        with self.assertRaises(StartupError):
            again.start()
        self.assertIsNotNone(again.process)

    def test_sigterm_exits_even_while_launcher_pipe_remains_open(self):
        runner = self.runner()
        runner.start()
        runner.process.terminate()
        self.assertEqual(runner.process.wait(timeout=5), 0)
        self.assertFalse(runner.process.stdin.closed)

    def test_close_rejects_incomplete_upload_without_forced_shutdown_or_wallet_creation(self):
        runner = self.runner(shutdown_timeout=2)
        endpoint = urlsplit(runner.start())
        token = (runner.data / 'auth_token').read_bytes()
        with socket.create_connection((endpoint.hostname, endpoint.port), timeout=3) as client:
            request = (f'POST /api/v1/wallet/create HTTP/1.1\r\nHost: {endpoint.netloc}\r\n'
                       f'Authorization: Bearer {token.decode().strip()}\r\n'
                       'Content-Type: application/json\r\nContent-Length: 100\r\n'
                       'Expect: 100-continue\r\n\r\n')
            client.sendall(request.encode())
            # 100 Continue proves the request reached its body reader. Keep the
            # socket open and send valid JSON without completing the HTTP body.
            self.assertTrue(client.recv(1024).startswith(b'HTTP/1.1 100 Continue'))
            client.sendall(b'{}')
            runner.close()
            self.assertEqual(runner.process.returncode, 0)
        self.assertFalse((runner.data / 'mnemonic').exists())
        replacement = self.runner()
        replacement.start()
        self.assertEqual((replacement.data / 'auth_token').read_bytes(), token)
        self.assertFalse((replacement.data / 'mnemonic').exists())

    def test_browser_handoff_is_authenticated_one_use_and_not_the_owner_token(self):
        runner = self.runner()
        runner.start()
        url = runner.browser_url()
        code = url.split('#desktop-handoff=', 1)[1]
        owner = (runner.data / 'auth_token').read_text().strip()
        self.assertTrue(code != owner)
        http = build_opener(ProxyHandler({}), NoRedirects())
        with self.assertRaises(HTTPError) as unauthenticated:
            http.open(Request(runner.endpoint + '/api/desktop/handoff/new', data=b''), timeout=2)
        self.assertEqual(unauthenticated.exception.code, 401)
        for origin, expected in [('https://untrusted.example', 403), (runner.endpoint, 200), (runner.endpoint, 403)]:
            request = Request(runner.endpoint + '/api/desktop/handoff/redeem',
                data=json.dumps({'code':code}).encode(),
                headers={'Origin':origin, 'Content-Type':'application/json'})
            if expected == 200:
                with http.open(request, timeout=2) as response:
                    self.assertEqual(response.headers['Cache-Control'], 'no-store')
                    self.assertTrue(json.loads(response.read())['token'] == owner)
            else:
                with self.assertRaises(HTTPError) as rejected:
                    http.open(request, timeout=2)
                self.assertEqual(rejected.exception.code, expected)
        self.assertFalse((runner.data / 'mnemonic').exists())

    def test_launcher_crash_releases_daemon_lock_and_allows_restart(self):
        ready = Path(self.temporary.name) / 'launcher-ready.json'
        script = '''
import json, sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from managed_daemon import ManagedDaemon
runner = ManagedDaemon(sys.argv[2], sys.argv[3])
runner.start()
marker = Path(sys.argv[4])
pending = marker.with_suffix('.tmp')
pending.write_text(json.dumps({'pid': runner.process.pid}))
pending.replace(marker)
while True:
    time.sleep(1)
'''
        launcher = subprocess.Popen([sys.executable, '-c', script,
            str(Path(__file__).parent.resolve()), str(BINARY), str(self.root), str(ready)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while not ready.exists():
                self.assertIsNone(launcher.poll(), 'Test launcher exited before readiness')
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.05)
            # The marker carries only a PID. The bearer token remains in the
            # isolated private data directory and never enters child arguments.
            self.assertGreater(json.loads(ready.read_text())['pid'], 0)
            token = (self.root / 'wallet' / 'auth_token').read_bytes()
            launcher.kill()
            launcher.wait(timeout=5)
            deadline = time.monotonic() + 10
            with (self.root / 'wallet' / 'barkd.lock').open('rb') as lock:
                while True:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        fcntl.flock(lock, fcntl.LOCK_UN)
                        break
                    except BlockingIOError:
                        self.assertLess(time.monotonic(), deadline,
                                        'Launcher death left the daemon lock held')
                        time.sleep(0.05)
            # No PID file, lock file or credential is deleted to permit recovery.
            replacement = self.runner()
            replacement.start()
            self.assertEqual((replacement.data / 'auth_token').read_bytes(), token)
            self.assertFalse((replacement.data / 'mnemonic').exists())
        finally:
            # A failed assertion may leave the original child alive. This process
            # group was created solely for this test, never for an installed app.
            try:
                os.killpg(launcher.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            launcher.wait(timeout=5)

    def test_unresponsive_owned_child_is_killed_with_explicit_recovery_error(self):
        stub = Path(self.temporary.name) / 'unresponsive-daemon'
        stub.write_text(f'#!{sys.executable}\nimport time\ntime.sleep(60)\n')
        stub.chmod(0o700)
        runner = ManagedDaemon(stub, self.root, startup_timeout=0.2, shutdown_timeout=0.2)
        self.addCleanup(runner.close)
        with self.assertRaisesRegex(StartupError, 'forced shutdown'):
            runner.start()
        self.assertIsNotNone(runner.process.poll())
        self.assertIsNone(runner._lock)

    def test_stale_discovery_is_not_contacted_and_timeout_reaps_owned_child(self):
        self.root.mkdir(mode=0o700)
        data = self.root / 'wallet'
        data.mkdir(mode=0o700)
        calls = []

        class OldEndpoint(BaseHTTPRequestHandler):
            def do_GET(self):
                calls.append(self.path)
                self.send_response(500)
                self.end_headers()

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), OldEndpoint)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            discovery = data / 'barkd.url'
            discovery.write_text(f'http://127.0.0.1:{server.server_port}')
            discovery.chmod(0o600)
            credential = data / 'auth_token'
            credential.write_text('A' * 44)
            credential.chmod(0o600)
            stub = Path(self.temporary.name) / 'unresponsive-daemon'
            stub.write_text(f'#!{sys.executable}\nimport sys\nsys.stdin.buffer.read()\n')
            stub.chmod(0o700)
            runner = ManagedDaemon(stub, self.root, startup_timeout=0.2)
            self.addCleanup(runner.close)
            with self.assertRaisesRegex(StartupError, 'in time'):
                runner.start()
            self.assertIsNotNone(runner.process.poll())
            self.assertIsNone(runner._lock)
            self.assertEqual(calls, [])
            self.assertEqual(credential.read_text(), 'A' * 44)
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)

    def test_does_not_attach_to_or_stop_an_independently_started_daemon(self):
        self.root.mkdir(mode=0o700)
        data = self.root / 'wallet'
        data.mkdir(mode=0o700)
        existing = subprocess.Popen([str(BINARY), '--quiet', '--no-logfile', '--datadir', str(data),
                                     '--host', '127.0.0.1', '--port', '0'],
                                    env={'PATH':os.environ['PATH'], 'HOME':self.temporary.name},
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 10
            while not (data / 'barkd.url').exists():
                self.assertIsNone(existing.poll())
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.05)
            saved = (data / 'barkd.url').read_bytes()
            runner = self.runner(startup_timeout=3)
            with self.assertRaises(StartupError):
                runner.start()
            self.assertIsNone(runner.endpoint)
            self.assertIsNone(existing.poll())
            self.assertEqual((data / 'barkd.url').read_bytes(), saved)
        finally:
            if existing.poll() is None:
                existing.terminate()
                try:
                    existing.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    existing.kill()
                    existing.wait(timeout=5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    args, remaining = parser.parse_known_args()
    if args.binary:
        BINARY = args.binary.resolve(strict=True)
        # unittest class decorators run before command-line parsing.
        RunnerLifecycle.__unittest_skip__ = False
    unittest.main(argv=[sys.argv[0]] + remaining)
