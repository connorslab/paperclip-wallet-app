"""Exercise the shell protocol with an isolated unfunded native daemon."""
import argparse
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import unittest


BINARY = None


@unittest.skipUnless(BINARY, 'Pass --binary for real daemon checks')
class LauncherBridge(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='paperclip-shell-qa-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'app'
        self.process = subprocess.Popen([sys.executable, '-I', str(Path(__file__).with_name('launcher_entry.py')),
            '--binary', str(BINARY), '--root', str(self.root)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(self.cleanup)
        self.assertEqual(self.event()['event'], 'ready')

    def cleanup(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait(timeout=5)
        self.process.stdout.close()

    def event(self):
        self.assertTrue(select.select([self.process.stdout], [], [], 10)[0], 'Desktop helper did not respond')
        line = self.process.stdout.readline(8193)
        self.assertTrue(0 < len(line) <= 8192, 'Invalid desktop helper response')
        return json.loads(line)

    def send(self, value):
        self.process.stdin.write(value)
        self.process.stdin.flush()

    def test_open_and_quit_share_no_owner_credential(self):
        owner = (self.root / 'wallet' / 'auth_token').read_text().strip()
        self.send(b'{"action":"open"}\n{"action":"quit"}\n')
        opened = self.event()
        self.assertEqual(opened['event'], 'open')
        self.assertTrue(opened['url'].startswith('http://127.0.0.1:'))
        self.assertTrue('#desktop-handoff=' in opened['url'])
        self.assertTrue(owner not in json.dumps(opened))
        self.assertEqual(self.event()['event'], 'stopped')
        self.assertEqual(self.process.wait(timeout=5), 0)
        self.assertFalse((self.root / 'wallet' / 'mnemonic').exists())

    def test_shell_eof_stops_cleanly(self):
        self.process.stdin.close()
        self.assertEqual(self.event()['event'], 'stopped')
        self.assertEqual(self.process.wait(timeout=5), 0)

    def test_daemon_exit_is_reported_without_waiting_for_user_action(self):
        pid = int((self.root / 'wallet' / 'barkd.lock').read_text())
        os.kill(pid, signal.SIGTERM)
        result = self.event()
        self.assertEqual(result['event'], 'error')
        self.assertIn('stopped unexpectedly', result['message'])
        self.assertEqual(self.process.wait(timeout=5), 1)

    def test_unrecognized_command_fails_closed_without_echoing_input(self):
        self.send(b'{"action":"pay","private":"synthetic-sensitive-input"}\n')
        result = self.event()
        self.assertEqual(result['event'], 'error')
        self.assertTrue('synthetic-sensitive-input' not in json.dumps(result))
        self.assertEqual(self.process.wait(timeout=5), 1)

    def test_oversized_request_stops_without_wallet_mutation(self):
        self.send(b'x' * 257)
        self.assertEqual(self.event()['event'], 'error')
        self.assertEqual(self.process.wait(timeout=5), 1)
        self.assertFalse((self.root / 'wallet' / 'mnemonic').exists())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args, remaining = parser.parse_known_args()
    BINARY = args.binary.resolve(strict=True)
    LauncherBridge.__unittest_skip__ = False
    unittest.main(argv=[sys.argv[0]] + remaining)
