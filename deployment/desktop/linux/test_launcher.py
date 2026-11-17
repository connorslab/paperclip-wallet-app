"""Headless controller checks using only an isolated unfunded owned daemon."""
import argparse
from pathlib import Path
import queue
import signal
import os
import sys
import tempfile
import unittest

from launcher import Session, valid_handoff

BINARY = None


class HandoffPolicy(unittest.TestCase):
    def test_only_exact_local_single_use_urls_reach_the_browser(self):
        good = 'http://127.0.0.1:1234/#desktop-handoff=' + 'a' * 44
        self.assertTrue(valid_handoff(good))
        for bad in (None, good + '\n', good.replace('127.0.0.1', 'localhost'),
                    good.replace('1234', '0'), good.replace('1234', '65536'),
                    good.replace('/#', '/path#'), good.replace('/#', '/?token=private#'),
                    good.replace('127.0.0.1', 'user@127.0.0.1'), good.replace('http:', 'file:'),
                    good[:-1], 'https://untrusted.example/' + good):
            self.assertFalse(valid_handoff(bad))


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
