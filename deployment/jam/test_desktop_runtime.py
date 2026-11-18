"""Real, unfunded Jam child lifecycle; requires the pinned companion environment."""
import fcntl
import json
import os
from pathlib import Path
import re
import selectors
import signal
import ssl
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.error import URLError
from urllib.request import HTTPSHandler, ProxyHandler, build_opener

ENTRY = Path(__file__).with_name('desktop-entry.py').resolve()


class DesktopRuntime(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve() / 'native-jam'
        self.children = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=10)
            for stream in (child.stdin, child.stdout, child.stderr):
                if stream and not stream.closed:
                    stream.close()
        self.temp.cleanup()

    def launch(self, root=None):
        child = subprocess.Popen([sys.executable, '-I', str(ENTRY), '--data-dir', str(root or self.root)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={**os.environ, 'JOINMARKET_DATA_DIR': '/must-not-use',
                 'JMWALLETD_HOST': '0.0.0.0', 'JMWALLETD_NO_TLS': '1',
                 'HTTPS_PROXY': 'http://127.0.0.1:1'}, start_new_session=True)
        self.children.append(child)
        return child

    def ready(self, child):
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(20), 'Owned Jam child did not report readiness')
        line = child.stdout.readline()
        self.assertTrue(line, 'Owned Jam child exited before readiness')
        value = json.loads(line)
        self.assertEqual(set(value), {'ready', 'endpoint'})
        self.assertTrue(value['ready'])
        self.assertTrue(value['endpoint'].startswith('https://127.0.0.1:'))
        return value['endpoint']

    def read_capabilities(self, endpoint, trusted=True):
        context = ssl.create_default_context(cafile=str(self.root / 'ssl/cert.pem')) if trusted else ssl.create_default_context()
        opener = build_opener(ProxyHandler({}), HTTPSHandler(context=context))
        with opener.open(endpoint + '/api/v1/paperclip/capabilities', timeout=5) as response:
            return json.load(response)

    def close(self, child):
        child.stdin.close()
        self.assertEqual(child.wait(timeout=25), 0)
        self.assertEqual(child.stdout.read(), b'')
        self.assertEqual(child.stderr.read(), b'')

    def rejected(self, child):
        child.stdin.close()
        self.assertEqual(child.wait(timeout=20), 1)
        self.assertEqual(child.stdout.read(), b'')
        lines = child.stderr.read().splitlines()
        self.assertEqual(len(lines), 2)
        prefix = b'Jars runtime diagnostic: '
        self.assertTrue(lines[0].startswith(prefix))
        diagnostic = json.loads(lines[0][len(prefix):])
        self.assertEqual(set(diagnostic), {'type', 'frames'})
        self.assertTrue(re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', diagnostic['type']) is not None)
        self.assertTrue(bool(diagnostic['frames']))
        for frame in diagnostic['frames']:
            self.assertTrue(re.fullmatch(r'[A-Za-z_0-9.\-]+:[0-9]+', frame) is not None,
                            'Diagnostic must contain source basenames and line numbers only')
        self.assertTrue(lines[1] == b'The private Jam runtime could not start or close safely.')

    def test_tls_readiness_lifetime_and_restart_preserve_identity(self):
        child = self.launch(); endpoint = self.ready(child)
        self.assertEqual(self.read_capabilities(endpoint)['version'], 2)
        with self.assertRaises(URLError): self.read_capabilities(endpoint, trusted=False)
        cert = (self.root / 'ssl/cert.pem').read_bytes()
        key = (self.root / 'ssl/key.pem').read_bytes()
        self.assertFalse(list(self.root.rglob('*.jmdat')), 'No wallet should be created')
        self.close(child)
        with self.assertRaises(URLError): self.read_capabilities(endpoint)
        restarted = self.launch(); self.read_capabilities(self.ready(restarted))
        self.assertEqual((self.root / 'ssl/cert.pem').read_bytes(), cert)
        self.assertEqual((self.root / 'ssl/key.pem').read_bytes(), key)
        self.close(restarted)

    def test_competing_child_cannot_replace_tls_or_disturb_owner(self):
        owner = self.launch(); endpoint = self.ready(owner)
        before = (self.root / 'ssl/cert.pem').read_bytes()
        self.rejected(self.launch())
        self.assertEqual((self.root / 'ssl/cert.pem').read_bytes(), before)
        self.read_capabilities(endpoint)
        self.close(owner)

    def test_signal_shutdown_with_open_parent_pipe_and_killed_child_restart(self):
        child = self.launch(); self.ready(child)
        cert = (self.root / 'ssl/cert.pem').read_bytes()
        child.terminate()  # Parent still holds stdin; do not deadlock finalization.
        # Uvicorn re-raises its captured termination signal after graceful shutdown.
        self.assertIn(child.wait(timeout=25), (0, -15))
        self.assertEqual(child.stderr.read(), b'')
        killed = self.launch(); self.ready(killed)
        killed.kill(); self.assertNotEqual(killed.wait(timeout=10), 0)
        restarted = self.launch(); self.read_capabilities(self.ready(restarted))
        self.assertEqual((self.root / 'ssl/cert.pem').read_bytes(), cert)
        self.close(restarted)

    def test_launcher_crash_closes_child_and_releases_runtime_lock(self):
        program = """
import subprocess, sys, time
child = subprocess.Popen([sys.executable, '-I', sys.argv[1], '--data-dir', sys.argv[2]],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
sys.stdout.buffer.write(child.stdout.readline()); sys.stdout.buffer.flush()
while True: time.sleep(10)
"""
        launcher = subprocess.Popen([sys.executable, '-I', '-c', program, str(ENTRY), str(self.root)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        stopped = False
        try:
            endpoint = self.ready(launcher)
            self.read_capabilities(endpoint)
            os.kill(launcher.pid, signal.SIGKILL)
            # Keep the parent unreaped until group cleanup so its group ID cannot
            # be recycled. Only this test-owned group can receive the final kill.
            deadline = time.monotonic() + 25
            while True:
                try:
                    self.read_capabilities(endpoint)
                except URLError:
                    break
                self.assertLess(time.monotonic(), deadline, 'Jam outlived its crashed launcher')
                time.sleep(0.05)
            # Listener closure precedes completion of graceful shutdown. Observe
            # lock release without repeatedly launching competing runtimes.
            with (self.root / 'desktop.lock').open('rb') as lock:
                while True:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        fcntl.flock(lock, fcntl.LOCK_UN)
                        break
                    except BlockingIOError:
                        self.assertLess(time.monotonic(), deadline, 'Jam retained its lock after launcher death')
                        time.sleep(0.05)
            restarted = self.launch(); self.read_capabilities(self.ready(restarted))
            stopped = True  # Original listener closed and runtime lock released.
            self.close(restarted)
        finally:
            if not stopped:
                try: os.killpg(launcher.pid, signal.SIGKILL)
                except ProcessLookupError: pass
            launcher.wait(timeout=10)
            launcher.stdout.close(); launcher.stderr.close()

    def test_incomplete_tls_is_not_rotated(self):
        for name in ('key.pem', 'cert.pem'):
            with self.subTest(name=name):
                root = self.root / name
                (root / 'ssl').mkdir(parents=True, mode=0o700)
                root.chmod(0o700)
                path = root / 'ssl' / name
                path.write_bytes(b'preserve incomplete identity'); path.chmod(0o600)
                self.rejected(self.launch(root))
                self.assertEqual(path.read_bytes(), b'preserve incomplete identity')
                self.assertEqual(len(list((root / 'ssl').iterdir())), 1)

    def test_linked_or_shared_root_is_refused(self):
        self.root.mkdir(mode=0o755)
        self.root.chmod(0o755)
        self.rejected(self.launch())
        self.root.chmod(0o700)
        link = self.root.parent / 'linked-jam'; link.symlink_to(self.root)
        self.rejected(self.launch(link))
        self.assertEqual(list(self.root.iterdir()), [])

    def test_parent_closes_before_readiness_without_orphan(self):
        child = self.launch()
        child.stdin.close()
        self.assertEqual(child.wait(timeout=25), 0)
        self.assertEqual(child.stdout.read(), b'')
        self.assertEqual(child.stderr.read(), b'')


if __name__ == '__main__':
    unittest.main()
