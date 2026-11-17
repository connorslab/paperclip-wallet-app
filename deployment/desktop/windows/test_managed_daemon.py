"""Native Windows owned-child checks with disposable, unfunded wallet storage."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

import win32api
import win32con
import win32event

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from managed_daemon import ManagedDaemon, StartupError, default_data_root
from pipe_io import read_available
from windows.private_storage import SessionRecord, private_directory, read_private_file

BINARY = None


class WindowsOwnership(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='paperclip-windows-owner-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'app'

    def runner(self, **options):
        runner = ManagedDaemon(BINARY, self.root, **options)
        self.addCleanup(runner.close)
        return runner

    def read(self, path):
        with read_private_file(path) as file:
            return file.read()

    def test_start_handoff_and_clean_close_preserve_private_identity(self):
        self.assertTrue(default_data_root().is_absolute())
        runner = self.runner(); runner.start()
        self.assertFalse(runner.recovery_required)
        token = self.read(runner.data / 'auth_token').strip().decode()
        url = runner.browser_url()
        self.assertTrue(url.startswith(runner.endpoint + '/#desktop-handoff='))
        self.assertTrue(token not in url)
        runner.close()
        self.assertEqual(runner.process.returncode, 0)
        self.assertEqual(self.read(self.root / 'session.state'), SessionRecord.CLOSED)
        restarted = self.runner(); restarted.start()
        self.assertFalse(restarted.recovery_required)
        self.assertTrue(self.read(restarted.data / 'auth_token').strip().decode() == token)
        self.assertFalse((runner.data / 'mnemonic').exists())

    def test_competing_launcher_cannot_adopt_or_stop_the_owner(self):
        owner = self.runner(); owner.start()
        competing = self.runner()
        with self.assertRaises(StartupError):
            competing.start()
        self.assertIsNone(competing.process)
        owner.ensure_running()

    def test_killed_wallet_retains_recovery_until_explicit_clean_restart(self):
        first = self.runner(); first.start()
        first.process.kill(); first.process.wait(timeout=5)
        with self.assertRaises(StartupError):
            first.ensure_running()
        first.close()
        self.assertEqual(self.read(self.root / 'session.state'), SessionRecord.ACTIVE)
        restarted = self.runner(); restarted.start()
        self.assertTrue(restarted.recovery_required)
        restarted.close()
        self.assertEqual(self.read(self.root / 'session.state'), SessionRecord.CLOSED)

    def test_bad_session_record_is_preserved_without_starting_a_child(self):
        private_directory(self.root)
        record = SessionRecord(self.root / 'session.state')
        record.begin(); record.finish(); record.close()
        (self.root / 'session.state').write_bytes(b'interrupted fixture')
        runner = self.runner()
        with self.assertRaises(StartupError):
            runner.start()
        self.assertIsNone(runner.process)
        self.assertEqual(self.read(self.root / 'session.state'), b'interrupted fixture')

    def test_unavailable_jars_runtime_does_not_silently_start_without_jars(self):
        runner = self.runner(jam_runtime=(sys.executable, None))
        with self.assertRaises(StartupError):
            runner.start()
        self.assertFalse(self.root.exists())

    def test_launcher_death_closes_child_lifetime_pipe_and_retains_recovery(self):
        code = ('from managed_daemon import ManagedDaemon; import sys\n'
                'runner = ManagedDaemon(sys.argv[1], sys.argv[2]); runner.start()\n'
                'print(runner.process.pid, flush=True); sys.stdin.buffer.read(1)\n')
        parent = subprocess.Popen([sys.executable, '-c', code, str(BINARY), str(self.root)],
            cwd=Path(__file__).resolve().parent.parent, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        child = None
        try:
            pending = b''
            deadline = time.monotonic() + 30
            while b'\n' not in pending:
                self.assertLess(time.monotonic(), deadline, 'Owned launcher did not become ready')
                chunk = read_available(parent.stdout.fileno(), 32, .1)
                if chunk is not None:
                    self.assertTrue(bool(chunk) and len(pending) + len(chunk) <= 64)
                    pending += chunk
            child = win32api.OpenProcess(win32con.SYNCHRONIZE | win32con.PROCESS_TERMINATE, False, int(pending))
            parent.kill(); parent.wait(timeout=5)
            self.assertEqual(win32event.WaitForSingleObject(child, 15000), win32event.WAIT_OBJECT_0)
            self.assertEqual(self.read(self.root / 'session.state'), SessionRecord.ACTIVE)
            restarted = self.runner(); restarted.start()
            self.assertTrue(restarted.recovery_required)
        finally:
            if parent.poll() is None:
                parent.kill()
            parent.wait(timeout=5)
            parent.stdin.close(); parent.stdout.close()
            if child is not None:
                if win32event.WaitForSingleObject(child, 0) == win32event.WAIT_TIMEOUT:
                    win32api.TerminateProcess(child, 1)
                    win32event.WaitForSingleObject(child, 5000)
                child.Close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    args, remaining = parser.parse_known_args()
    BINARY = args.binary.resolve(strict=True)
    unittest.main(argv=[sys.argv[0]] + remaining)
