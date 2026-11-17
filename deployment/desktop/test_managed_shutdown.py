"""Real daemon shutdown during an isolated, TLS-validated, read-only Jam request.

This proves handler/launcher lifecycle behavior, not payment settlement or Jam
hosting. No wallet is created, no production endpoint is used, and all temporary
credentials and TLS material stay in the test directory.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from types import SimpleNamespace
from urllib.request import Request, build_opener, ProxyHandler
from urllib.parse import urlsplit

from managed_daemon import ManagedDaemon, NoRedirects, StartupError


try:
    import fcntl
except ImportError:
    fcntl = None

BINARY = None


@unittest.skipUnless(BINARY and os.name == 'posix', 'Pass --binary on Linux or macOS')
class ActiveHandlerShutdown(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='paperclip-shutdown-qa-')
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.root = root / 'app'
        config = root / 'tls.conf'
        config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n'
                          '[dn]\nCN=localhost\n[ext]\nsubjectAltName=IP:127.0.0.1\n'
                          'basicConstraints=critical,CA:FALSE\n'
                          'keyUsage=critical,digitalSignature,keyEncipherment\n')
        certificate, key = root / 'certificate.pem', root / 'key.pem'
        result = subprocess.run(['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-x509',
                                 '-sha256', '-nodes', '-days', '1', '-config', str(config),
                                 '-keyout', str(key), '-out', str(certificate)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        self.assertEqual(result.returncode, 0, 'Could not create isolated TLS fixture')
        key.chmod(0o600)
        self.entered, self.release = threading.Event(), threading.Event()
        self.calls = []
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                fixture.calls.append(self.path)
                fixture.entered.set()
                if not fixture.release.wait(timeout=15):
                    return
                body = b'{"wallets":[]}'
                try:
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                    pass  # The forced-shutdown case deliberately closes its client.

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(certificate, key)
        self.server.socket = tls.wrap_socket(self.server.socket, server_side=True)
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.worker.start()
        self.addCleanup(self.stop_fixture)
        # Only this disposable wrapper injects the fixture endpoint. The actual
        # launcher still strips ambient environment; the child is the real daemon.
        wrapper = root / 'fixture-daemon'
        wrapper.write_text('#!/bin/sh\nexec env '
                           + shlex.quote('BARKD_JOINBLAKET_URL=https://127.0.0.1:' + str(self.server.server_port))
                           + ' ' + shlex.quote('BARKD_JOINBLAKET_CA_FILE=' + str(certificate))
                           + ' ' + shlex.quote(str(BINARY)) + ' "$@"\n')
        wrapper.chmod(0o700)
        self.wrapper = wrapper

    def stop_fixture(self):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.worker.join(timeout=3)

    def start(self, timeout=5):
        runner = ManagedDaemon(self.wrapper, self.root, shutdown_timeout=timeout)
        self.addCleanup(runner.close)
        runner.start()
        return runner

    def request(self, runner, path, body=None):
        token = (runner.data / 'auth_token').read_text().strip()
        http = build_opener(ProxyHandler({}), NoRedirects())
        request = Request(runner.endpoint + path, headers={
            'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
            data=None if body is None else json.dumps(body).encode())
        with http.open(request, timeout=10) as response:
            return json.loads(response.read())

    def pending_read(self, runner):
        result = []

        def fetch():
            try:
                result.append(self.request(runner, '/api/v1/joinblaket/request', {'operation': 'wallets'}))
            except Exception:
                result.append('interrupted')  # Never print requests or credentials.

        client = threading.Thread(target=fetch, daemon=True)
        client.start()
        self.addCleanup(client.join, 10)
        self.addCleanup(self.release.set)
        self.assertTrue(self.entered.wait(timeout=5), 'Request did not reach the TLS fixture')
        self.assertEqual(self.calls, ['/api/v1/wallet/all'])
        self.assertTrue(client.is_alive(), 'The handler was not held open')
        return client, result

    def assert_restarted_without_replay(self, previous_token, recovery):
        replacement = self.start()
        self.assertEqual(replacement.recovery_required, recovery)
        self.assertTrue((replacement.data / 'auth_token').read_bytes() == previous_token,
                        'Authentication changed across restart')
        self.assertEqual(self.request(replacement, '/api/v1/wallet'), {'fingerprint': None})
        self.assertFalse((replacement.data / 'mnemonic').exists())
        self.assertEqual(self.calls, ['/api/v1/wallet/all'], 'Restart replayed the previous request')
        replacement.close()
        self.assertFalse((self.root / 'session.active').exists())

    def assert_listener_closed(self, address):
        # Prove shutdown began while the already-dispatched request is active.
        deadline = time.monotonic() + 3
        while True:
            try:
                with socket.create_connection((address.hostname, address.port), timeout=0.2):
                    pass
            except OSError:
                return
            self.assertLess(time.monotonic(), deadline, 'Daemon did not stop accepting requests')
            time.sleep(0.02)

    def test_close_drains_dispatched_read_before_clearing_recovery_marker(self):
        runner = self.start()
        token = (runner.data / 'auth_token').read_bytes()
        client, result = self.pending_read(runner)
        address = urlsplit(runner.endpoint)
        close_errors = []

        def close():
            try:
                runner.close()
            except Exception:
                close_errors.append('shutdown failed')

        closer = threading.Thread(target=close, daemon=True)
        closer.start()
        self.addCleanup(closer.join, 10)
        self.addCleanup(self.release.set)
        self.assert_listener_closed(address)
        self.assertIsNone(runner.process.poll(), 'Shutdown canceled an active handler')
        self.assertTrue(client.is_alive())
        self.assertTrue((self.root / 'session.active').exists())
        self.release.set()
        closer.join(timeout=3)
        self.assertFalse(closer.is_alive())
        self.assertEqual(close_errors, [])
        client.join(timeout=3)
        self.assertFalse(client.is_alive())
        self.assertEqual(result, [{'wallets': []}])
        self.assertEqual(runner.process.returncode, 0)
        self.assertFalse((self.root / 'session.active').exists())
        self.assert_restarted_without_replay(token, recovery=False)

    def test_forced_close_of_dispatched_read_preserves_recovery_marker(self):
        runner = self.start(timeout=0.5)
        token = (runner.data / 'auth_token').read_bytes()
        client, result = self.pending_read(runner)
        with self.assertRaisesRegex(StartupError, 'forced shutdown'):
            runner.close()
        client.join(timeout=3)
        self.assertFalse(client.is_alive())
        self.assertEqual(result, ['interrupted'])
        self.assertIsNotNone(runner.process.poll())
        self.assertNotEqual(runner.process.returncode, 0)
        self.assertTrue((self.root / 'session.active').exists())
        self.release.set()
        self.assert_restarted_without_replay(token, recovery=True)


    def test_launcher_death_drains_active_read_and_preserves_recovery_warning(self):
        ready = Path(self.temporary.name) / 'owner-ready'
        script = """
import sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from managed_daemon import ManagedDaemon
runner = ManagedDaemon(sys.argv[2], sys.argv[3])
runner.start()
Path(sys.argv[4]).write_text('ready')
while True:
    time.sleep(1)
"""
        owner = subprocess.Popen([sys.executable, '-c', script,
            str(Path(__file__).parent.resolve()), str(self.wrapper), str(self.root), str(ready)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while not ready.exists():
                self.assertIsNone(owner.poll(), 'Test owner exited before readiness')
                self.assertLess(time.monotonic(), deadline, 'Test owner did not become ready')
                time.sleep(0.05)
            data = self.root / 'wallet'
            endpoint = (data / 'barkd.url').read_text()
            token = (data / 'auth_token').read_bytes()
            client, result = self.pending_read(SimpleNamespace(data=data, endpoint=endpoint))
            owner.kill()
            owner.wait(timeout=5)
            self.assert_listener_closed(urlsplit(endpoint))
            self.assertTrue(client.is_alive(), 'Owner death canceled the dispatched handler')
            self.assertTrue((self.root / 'session.active').exists())
            with (data / 'barkd.lock').open('rb') as lock:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.release.set()
                client.join(timeout=3)
                self.assertFalse(client.is_alive())
                self.assertEqual(result, [{'wallets': []}])
                deadline = time.monotonic() + 5
                while True:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        fcntl.flock(lock, fcntl.LOCK_UN)
                        break
                    except BlockingIOError:
                        self.assertLess(time.monotonic(), deadline, 'Orphan daemon retained its lock')
                        time.sleep(0.02)
            self.assert_restarted_without_replay(token, recovery=True)
        finally:
            self.release.set()
            # This session contains only the disposable test owner and daemon.
            try:
                os.killpg(owner.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            owner.wait(timeout=5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args, remaining = parser.parse_known_args()
    BINARY = args.binary.resolve(strict=True)
    ActiveHandlerShutdown.__unittest_skip__ = os.name != 'posix'
    unittest.main(argv=[sys.argv[0]] + remaining)
