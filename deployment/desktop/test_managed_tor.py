"""Owned Tor checks with networking disabled, no nodes, keys or payments."""
import argparse
from contextlib import ExitStack
import io
import importlib.util
import os
from pathlib import Path
import socket
import sys
import tempfile
import unittest
from unittest.mock import patch

from managed_tor import Control, ManagedTor
from managed_daemon import StartupError

if os.name == 'nt':
    from windows.private_storage import atomic_write_private, exclusive_file, private_directory, SessionRecord

BINARY = None
NETWORK = False


class Connection:
    def __init__(self, reply):
        self.stream = io.BytesIO(reply)
        self.sent = b''
    def makefile(self, _mode): return self.stream
    def sendall(self, data): self.sent += data
    def close(self): pass


class Replies(unittest.TestCase):
    def test_multiline_reply_is_consumed_to_its_terminator(self):
        connection = Connection(b'250-net/listeners/socks="127.0.0.1:1234"\r\n250 OK\r\n250 OK\r\n')
        control = Control(connection)
        self.assertEqual(control.command('GETINFO net/listeners/socks'), ['net/listeners/socks="127.0.0.1:1234"', 'OK'])
        self.assertEqual(control.command('TAKEOWNERSHIP'), ['OK'])

    def test_errors_events_partial_and_oversized_replies_fail_without_echo(self):
        for value in (b'515 synthetic-private-error\r\n', b'650 STATUS_CLIENT private\r\n', b'250 OK\n',
                      b'250+data\r\n', b'250-' + b'x' * 4096 + b'\r\n', b'250-' + b'x' * 1000 + b'\r\n'):
            connection = Connection(value)
            with self.assertRaises(StartupError) as error: Control(connection).command('TEST')
            self.assertNotIn('private-error', str(error.exception))
        with self.assertRaises(StartupError): Control(Connection(b'250-more\r\n' * 16)).command('TEST')

    def test_control_command_cannot_inject_another_command(self):
        connection = Connection(b'250 OK\r\n')
        with self.assertRaises(StartupError): Control(connection).command('GETINFO\r\nSIGNAL NEWNYM')
        self.assertEqual(connection.sent, b'')

    def test_bootstrap_accepts_notice_and_warning_without_returning_summary(self):
        for level in ('NOTICE', 'WARN'):
            tor = ManagedTor(sys.executable, Path(tempfile.gettempdir()) / 'unused-tor-test')
            tor.control = Control(Connection(('250-status/bootstrap-phase=' + level + ' BOOTSTRAP PROGRESS=42 SUMMARY="private"\r\n250 OK\r\n').encode()))
            with patch.object(tor, 'ensure_running'):
                self.assertEqual(tor.bootstrap_progress(), 42)


class JamBinding(unittest.TestCase):
    def test_only_explicit_complete_binding_reaches_jam_settings(self):
        spec = importlib.util.spec_from_file_location('tor_jam_entry', Path(__file__).parent.parent / 'jam/desktop-entry.py')
        entry = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(entry)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / 'jars'
            entry.private_directory(root)
            cookie = root / 'synthetic-cookie'
            if os.name == 'nt':
                atomic_write_private(cookie, bytes(32))
            else:
                cookie.write_bytes(bytes(32)); cookie.chmod(0o600)
            with patch.dict(os.environ, {'TOR__SOCKS_HOST':'remote.example', 'TOR__PASSWORD':'synthetic-secret',
                    'BITCOIN__RPC_PASSWORD':'synthetic-node-secret'}):
                clean = entry.runtime_environment(root)
                self.assertNotIn('TOR__SOCKS_HOST', clean)
                owned = entry.runtime_environment(root, (1234, 5678, cookie))
            self.assertEqual(owned['TOR__SOCKS_HOST'], '127.0.0.1')
            self.assertEqual(owned['TOR__SOCKS_PORT'], '1234')
            self.assertEqual(owned['TOR__CONTROL_PORT'], '5678')
            self.assertEqual(owned['TOR__COOKIE_PATH'], str(cookie))
            self.assertEqual(owned['TOR__CONTROL_ENABLED'], 'true')
            self.assertNotIn('TOR__PASSWORD', owned)
            self.assertNotIn('BITCOIN__RPC_PASSWORD', owned)
            for binding in [(0, 5678, cookie), (1234, 65536, cookie), (1234, 1234, cookie), (1234, 5678, Path('relative-cookie'))]:
                with self.assertRaises(ValueError): entry.runtime_environment(root, binding)
            cookie.unlink()
            with self.assertRaises(FileNotFoundError): entry.runtime_environment(root, (1234, 5678, cookie))


class Native(unittest.TestCase):
    def setUp(self):
        if BINARY is None: self.skipTest('Supply a reviewed native Tor executable')
        self.temp = tempfile.TemporaryDirectory(prefix='paperclip-tor-qa-')
        self.root = Path(self.temp.name).resolve() / 'tor'
        self.children = []
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for tor in reversed(self.children): tor.close()
        self.temp.cleanup()

    def start(self):
        tor = ManagedTor(BINARY, self.root)
        self.children.append(tor)
        try:
            result = tor.start(network_enabled=False)
        except StartupError as error:
            code = getattr(error.__context__, 'winerror', None)
            if type(code) is int:
                self.fail(f'{error} Windows error code: {code}')
            raise
        self.assertEqual(tor.bootstrap_progress(), 0)
        self.assertEqual(set(result), {'socks_port', 'control_port', 'cookie_path'})
        return tor

    def test_private_dynamic_listeners_clean_close_and_retry(self):
        first = self.start()
        self.assertIsNone(first.socks_port, 'Disabled network must not advertise a SOCKS listener')
        cookie = first.cookie
        first.close()
        self.assertEqual(first.process.returncode, 0)
        self.assertFalse(cookie.exists())
        second = self.start()
        self.assertNotEqual(second.cookie, cookie)
        second.close()
        self.assertFalse(list(self.root.glob('control-*')))

    def test_explicit_network_activation_publishes_socks_after_control_auth(self):
        if not NETWORK: self.skipTest('Network activation requires --network')
        tor = self.start()
        port = tor.enable_network()
        self.assertNotEqual(port, tor.control_port)
        with socket.create_connection(('127.0.0.1', port), timeout=2) as socks:
            socks.sendall(b'\x05\x01\x00')
            self.assertEqual(socks.recv(2), b'\x05\x00')
        self.assertIn(tor.bootstrap_progress(), range(101))
        tor.close()
        self.assertEqual(tor.process.returncode, 0)

    def test_linux_expert_uses_its_packaged_libraries(self):
        if not sys.platform.startswith('linux') or not (BINARY.parent / 'libcrypto.so.3').is_file():
            self.skipTest('Requires the native Linux expert runtime')
        tor = self.start()
        maps = Path('/proc') / str(tor.process.pid) / 'maps'
        loaded = maps.read_text()
        for name in ('libcrypto.so.3', 'libssl.so.3', 'libevent-2.1.so.7'):
            self.assertIn(str((BINARY.parent / name).resolve()), loaded)

    def test_windows_launcher_storage_locks_allow_control_publication(self):
        if os.name != 'nt': self.skipTest('Requires the Windows launcher storage locks')
        app = self.root.parent / 'app'
        private_directory(app)
        self.root = app / 'tor'
        with ExitStack() as resources:
            resources.enter_context(exclusive_file(app / 'launcher.lock'))
            session = SessionRecord(app / 'session.state')
            resources.callback(session.close)
            session.begin()
            for _ in range(3):
                try:
                    self.start().close()
                except StartupError as error:
                    cause = error.__context__
                    code = getattr(cause, 'winerror', None)
                    # Only an integer OS code, never exception args or metadata.
                    if type(code) is int:
                        self.fail(f'{error} Windows error code: {code}')
                    raise
            session.finish()

    def test_second_owner_cannot_attach_or_stop_first(self):
        owner = self.start()
        second = ManagedTor(BINARY, self.root, startup_timeout=2)
        self.children.append(second)
        with self.assertRaises(StartupError): second.start(network_enabled=False)
        owner.ensure_running()
        self.assertEqual(owner.bootstrap_progress(), 0)

    def test_owning_control_loss_stops_only_its_child(self):
        tor = self.start()
        tor.control.close()
        tor.control = None
        tor.process.wait(timeout=10)
        with self.assertRaises(StartupError): tor.ensure_running()
        tor.close()
        self.start().close()

    def test_activation_timeout_reports_stage_cleans_up_and_allows_fresh_start(self):
        tor = ManagedTor(BINARY, self.root)
        self.children.append(tor)
        with patch.object(tor, 'enable_network', side_effect=TimeoutError('synthetic-private-metadata')):
            with self.assertRaises(StartupError) as error: tor.start()
        self.assertIn('opening its SOCKS connection', str(error.exception))
        self.assertNotIn('synthetic-private-metadata', str(error.exception))
        self.assertIsNotNone(tor.process.returncode)
        self.assertFalse(list(self.root.glob('control-*')))
        self.start().close()

    def test_failed_launch_cleans_session_and_does_not_claim_readiness(self):
        tor = ManagedTor(sys.executable, self.root, startup_timeout=2)
        self.children.append(tor)
        with self.assertRaises(StartupError): tor.start(network_enabled=False)
        self.assertIsNone(tor.control_port)
        self.assertFalse(list(self.root.glob('control-*')))
        self.start().close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tor', type=Path)
    parser.add_argument('--network', action='store_true', help='Permit the isolated Tor child to contact relays; no node or payment requests')
    args, remaining = parser.parse_known_args()
    NETWORK = args.network
    BINARY = args.tor.resolve(strict=True) if args.tor else None
    unittest.main(argv=[sys.argv[0]] + remaining)
