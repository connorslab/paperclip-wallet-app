"""Real native Jam supervision and optional wallet-proxy tests in unfunded storage."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from urllib.request import Request, ProxyHandler, build_opener
from unittest.mock import patch

from managed_daemon import ManagedDaemon, StartupError, private_directory, private_file
from managed_jam import ManagedJam

PYTHON = ENTRY = BINARY = TOR = None


class JamOwnership(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve() / 'app'
        self.children = []

    def tearDown(self):
        for child in reversed(self.children):
            try: child.close()
            except StartupError: pass
        self.temp.cleanup()

    def jam(self):
        child = ManagedJam(PYTHON, ENTRY, self.root / 'jars')
        self.children.append(child)
        return child

    def read(self, path):
        with private_file(path) as file:
            return file.read()

    def recovery_active(self):
        if os.name == 'nt':
            from windows.private_storage import SessionRecord
            return self.read(self.root / 'session.state') == SessionRecord.ACTIVE
        return (self.root / 'session.active').exists()

    def test_verified_readiness_and_clean_close(self):
        child = self.jam(); environment = child.start()
        self.assertEqual(set(environment), {'BARKD_JOINBLAKET_URL', 'BARKD_JOINBLAKET_CA_FILE'})
        self.assertEqual(environment['BARKD_JOINBLAKET_URL'], child.endpoint)
        child.ensure_running()
        child.close()
        self.assertEqual(child.process.returncode, 0)
        self.assertIsNone(child.endpoint)
        self.assertFalse(list(self.root.rglob('*.jmdat')))

    def test_competing_owner_is_not_adopted(self):
        owner = self.jam(); owner.start()
        second = self.jam()
        with self.assertRaises(StartupError): second.start()
        owner.ensure_running()
        self.assertIsNone(second.endpoint)
        self.assertIsNotNone(second.process.returncode)

    def test_missing_trust_rejects_readiness_and_reaps_owned_child(self):
        child = self.jam()
        with patch('managed_jam.ssl.create_default_context', side_effect=ValueError('synthetic TLS failure')):
            with self.assertRaises(StartupError) as result: child.start()
        self.assertNotIn('synthetic TLS failure', str(result.exception))
        self.assertIsNotNone(child.process.returncode)
        self.assertIsNone(child.endpoint)

    def test_crash_is_reported_and_identity_preserved_on_explicit_restart(self):
        child = self.jam(); child.start()
        certificate = self.read(child.root / 'ssl/cert.pem')
        child.process.kill(); child.process.wait(timeout=5)
        with self.assertRaises(StartupError): child.ensure_running()
        with self.assertRaises(StartupError): child.close()
        restarted = self.jam(); restarted.start()
        self.assertEqual(self.read(child.root / 'ssl/cert.pem'), certificate)


class WalletAndJam(JamOwnership):
    # Avoid inheriting and repeating the individual-child cases.
    test_verified_readiness_and_clean_close = None
    test_competing_owner_is_not_adopted = None
    test_missing_trust_rejects_readiness_and_reaps_owned_child = None
    test_crash_is_reported_and_identity_preserved_on_explicit_restart = None

    def wallet(self, tor_binary=None):
        runner = ManagedDaemon(BINARY, self.root, jam_runtime=(PYTHON, ENTRY), tor_binary=tor_binary)
        self.children.append(runner)
        runner.start()
        return runner

    def request(self, runner, path, body=None):
        token = self.read(runner.data / 'auth_token').decode().strip()
        request = Request(runner.endpoint + path, headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
                          data=json.dumps(body).encode() if body is not None else None)
        with build_opener(ProxyHandler({})).open(request, timeout=5) as response:
            return json.load(response)

    def test_wallet_discovers_and_reads_its_owned_jars_with_tls(self):
        runner = self.wallet()
        connection = self.request(runner, '/api/v1/joinblaket/connection')
        self.assertTrue(connection['configured'])
        self.assertIsNone(connection['ui_url'])
        self.assertEqual(self.request(runner, '/api/v1/joinblaket/request', {'operation':'wallets'})['wallets'], [])
        self.assertFalse(list(self.root.rglob('*.jmdat')))
        self.assertFalse((runner.data / 'mnemonic').exists())
        jam = runner.jam.process
        runner.close()
        self.assertEqual(jam.returncode, 0)
        self.assertEqual(runner.process.returncode, 0)
        self.assertFalse(self.recovery_active())

    def test_jars_crash_retains_recovery_warning_and_stops_wallet(self):
        runner = self.wallet()
        runner.jam.process.kill(); runner.jam.process.wait(timeout=5)
        with self.assertRaises(StartupError): runner.ensure_running()
        with self.assertRaises(StartupError): runner.close()
        self.assertIsNotNone(runner.process.returncode)
        self.assertTrue(self.recovery_active())
        restarted = self.wallet()
        self.assertTrue(restarted.recovery_required)
        restarted.close()
        self.assertFalse(self.recovery_active())

    def test_owned_tor_failure_stops_jars_and_keeps_recovery_warning(self):
        if TOR is None: self.skipTest('Supply --tor for explicit native Tor/Jars acceptance')
        runner = self.wallet(tor_binary=TOR)
        tor = runner.jam.tor
        self.assertIsNotNone(tor.socks_port)
        tor.ensure_running()
        self.assertIn(tor.bootstrap_progress(), range(101))
        tor.process.kill(); tor.process.wait(timeout=5)
        with self.assertRaises(StartupError): runner.ensure_running()
        # Failure is surfaced before close, so the launcher must retain the
        # same unresolved-session marker as other unexpected child exits.
        with self.assertRaises(StartupError): runner.close()
        self.assertTrue(self.recovery_active())
        self.assertIsNotNone(runner.jam.process.returncode)
        self.assertIsNotNone(runner.process.returncode)
        self.assertFalse(list((self.root / 'tor').glob('control-*')))

    def test_wallet_startup_failure_stops_jars_and_preserves_warning(self):
        runner = ManagedDaemon(BINARY, self.root, jam_runtime=(PYTHON, ENTRY))
        private_directory(self.root)
        private_directory(runner.data)
        if os.name == 'nt':
            from windows.private_storage import atomic_write_private
            atomic_write_private(runner.data / 'auth_token', b'invalid fixture')
        else:
            (runner.data / 'auth_token').write_text('invalid fixture')
        self.children.append(runner)
        with self.assertRaises(StartupError): runner.start()
        self.assertIsNotNone(runner.jam.process.returncode)
        self.assertTrue(self.recovery_active())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python', required=True, type=Path)
    parser.add_argument('--entry', type=Path)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--tor', type=Path)
    args, remaining = parser.parse_known_args()
    PYTHON, ENTRY = args.python.absolute(), args.entry.resolve(strict=True) if args.entry else None
    TOR = args.tor.resolve(strict=True) if args.tor else None
    BINARY = args.binary.resolve(strict=True) if args.binary else None
    if not BINARY:
        WalletAndJam.__unittest_skip__ = True
        WalletAndJam.__unittest_skip_why__ = 'Supply a native wallet daemon for combined hosting tests'
    unittest.main(argv=[sys.argv[0]] + remaining)
