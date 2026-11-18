"""Headless controller checks using only an isolated unfunded owned daemon."""
import argparse
from pathlib import Path
import queue
import signal
import os
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

from launcher import Session, Window, valid_handoff, open_default_browser

BINARY = None


class HandoffPolicy(unittest.TestCase):
    def test_frozen_browser_does_not_inherit_bundled_loader_paths(self):
        for original in (None, '/user/selected/lib'):
            environment = {'LD_LIBRARY_PATH':'/bundled/runtime', 'PATH':'/usr/bin'}
            if original is not None:
                environment['LD_LIBRARY_PATH_ORIG'] = original
            with patch.object(sys, 'frozen', True, create=True), patch.dict(os.environ, environment, clear=True), patch('launcher.subprocess.run') as run:
                run.return_value.returncode = 0
                self.assertTrue(open_default_browser('http://127.0.0.1:1234/#desktop-handoff=' + 'a' * 44))
                child = run.call_args.kwargs['env']
                self.assertEqual(child.get('LD_LIBRARY_PATH'), original)
                self.assertNotIn('LD_LIBRARY_PATH_ORIG', child)
                self.assertEqual(os.environ['LD_LIBRARY_PATH'], '/bundled/runtime')

    def test_only_exact_local_single_use_urls_reach_the_browser(self):
        good = 'http://127.0.0.1:1234/#desktop-handoff=' + 'a' * 44
        self.assertTrue(valid_handoff(good))
        for bad in (None, good + '\n', good.replace('127.0.0.1', 'localhost'),
                    good.replace('1234', '0'), good.replace('1234', '65536'),
                    good.replace('/#', '/path#'), good.replace('/#', '/?token=private#'),
                    good.replace('127.0.0.1', 'user@127.0.0.1'), good.replace('http:', 'file:'),
                    good[:-1], 'https://untrusted.example/' + good):
            self.assertFalse(valid_handoff(bad))


class BrowserCompletion(unittest.TestCase):
    def test_late_setup_progress_does_not_touch_a_cancelled_panel(self):
        window = Window.__new__(Window)
        window.state, window.quitting, window.setup_panel = 'starting', False, None
        window.root, window.setup_message = Mock(), Mock()
        window.session = Mock()
        window.session.events = queue.Queue()
        window.session.events.put(('setup_progress', 'Verifying your XBT node…'))
        window.session.events.put(('setup_error', 'Check the node address.'))
        window.poll()
        window.setup_message.configure.assert_not_called()

    def test_damaged_tor_fails_before_any_wallet_child_or_storage(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'untouched-wallet'
            with patch('launcher.ManagedDaemon') as daemon:
                session = Session(Path('unused'), root, tor_runtime=Path(temporary) / 'missing-tor')
                session.run()
                event, message = session.events.get_nowait()
                self.assertEqual(event, 'error')
                self.assertIn('Reinstall Paperclip', message)
                self.assertNotIn(str(root), message)
                self.assertEqual(session.events.get_nowait()[0], 'closed')
                daemon.assert_not_called()
                self.assertFalse(root.exists())

    def test_late_browser_result_cannot_replace_daemon_failure(self):
        # A browser process can return after the owned daemon has failed.
        # Drive queued completions without Tk so the race stays deterministic.
        for state in ('failed', 'closed', 'ready'):
            for event, value in (('opened', True), ('opened', False), ('open_error', 'Browser unavailable')):
                with self.subTest(state=state, event=event, value=value):
                    window = Window.__new__(Window)
                    window.state = state
                    window.failure = 'Your wallet stopped unexpectedly.'
                    window.quitting = False
                    window.root, window.status, window.action, window.progress = Mock(), Mock(), Mock(), Mock()
                    window.session = Mock()
                    window.session.events = queue.Queue()
                    window.session.events.put((event, value))
                    # Keep cleanup in progress for the closed-state case.
                    window.session.thread.is_alive.return_value = True
                    window.poll()
                    window.status.configure.assert_not_called()
                    window.action.configure.assert_not_called()
                    self.assertEqual(window.state, state)


@unittest.skipUnless(BINARY, 'Pass --binary for real native daemon checks')
class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='paperclip-linux-session-qa-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'app'
        self.sessions = []
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for session in self.sessions:
            session.close()
            session.thread.join(timeout=35)
            self.assertFalse(session.thread.is_alive())

    def start(self):
        session = Session(BINARY, self.root)
        self.sessions.append(session)
        session.start()
        event, recovery = self.event(session)
        self.assertEqual(event, 'ready')
        return session, recovery

    def event(self, session):
        try:
            return session.events.get(timeout=10)
        except queue.Empty:
            self.fail('Owned wallet session did not report its state')

    def test_open_close_and_crash_retry_preserve_authentication_and_warning(self):
        first, recovery = self.start()
        self.assertFalse(recovery)
        first.open()
        kind, url = self.event(first)
        self.assertEqual(kind, 'open')
        self.assertTrue(valid_handoff(url))
        owner = (self.root / 'wallet' / 'auth_token').read_bytes()
        self.assertTrue(owner.strip().decode() not in url)
        first.close()
        self.assertEqual(self.event(first)[0], 'closed')
        first.thread.join(timeout=5)
        self.assertFalse((self.root / 'session.active').exists())
        second, recovery = self.start()
        self.assertFalse(recovery)
        os.kill(int((self.root / 'wallet' / 'barkd.lock').read_text()), signal.SIGKILL)
        self.assertEqual(self.event(second)[0], 'error')
        self.assertEqual(self.event(second)[0], 'closed')
        second.thread.join(timeout=5)
        third, recovery = self.start()
        self.assertTrue(recovery)
        self.assertTrue((self.root / 'wallet' / 'auth_token').read_bytes() == owner)
        self.assertFalse((self.root / 'wallet' / 'mnemonic').exists())

    def test_close_during_start_never_emits_browser_handoff(self):
        session = Session(BINARY, self.root)
        self.sessions.append(session)
        session.close()
        session.start()
        self.assertEqual(self.event(session)[0], 'closed')
        session.thread.join(timeout=5)
        self.assertTrue(session.events.empty())
        self.assertFalse(self.root.exists())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    args, remaining = parser.parse_known_args()
    if args.binary:
        BINARY = args.binary.resolve(strict=True)
        Lifecycle.__unittest_skip__ = False
    unittest.main(argv=[sys.argv[0]] + remaining)
