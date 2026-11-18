import base64
import importlib.util
import os
import stat
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('entrypoint', Path(__file__).with_name('container-entrypoint.py'))
entrypoint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(entrypoint)


class BootstrapTest(unittest.TestCase):
    def test_password_is_auth_only_and_restart_preserves_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory) / 'wallet'
            password = '12' * 32
            entrypoint.prepare_auth(data, password)
            self.assertEqual(set(p.name for p in data.iterdir()), {'auth_token'})
            token = (data / 'auth_token').read_text()
            self.assertEqual(base64.urlsafe_b64decode(token), b'\0' + bytes.fromhex(password))
            (data / 'mnemonic').write_text('existing-key-material')
            entrypoint.prepare_auth(data, password)
            self.assertEqual((data / 'mnemonic').read_text(), 'existing-key-material')
            with self.assertRaises(ValueError):
                entrypoint.prepare_auth(data, '34' * 32)
            self.assertEqual((data / 'auth_token').read_text(), token)
            entrypoint.prepare_auth(data)

    def test_native_auth_is_left_to_daemon(self):
        with tempfile.TemporaryDirectory() as directory:
            entrypoint.prepare_auth(directory)
            self.assertEqual(list(Path(directory).iterdir()), [])
            with self.assertRaises(ValueError):
                entrypoint.prepare_auth(directory, 'weak-password')

    def test_corrupt_backup_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'auth_token').write_text('invalid')
            with self.assertRaises(ValueError):
                entrypoint.prepare_auth(directory)


    def test_shared_authentication_is_rejected_without_repairing_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory) / 'wallet'
            entrypoint.prepare_auth(data, '12' * 32)
            token = data / 'auth_token'
            token.chmod(0o644)
            with self.assertRaises(ValueError):
                entrypoint.prepare_auth(data)
            self.assertEqual(stat.S_IMODE(token.stat().st_mode), 0o644)
            token.chmod(0o600)
            alias = Path(directory) / 'other-token'
            os.link(token, alias)
            original = alias.read_bytes()
            with self.assertRaises(ValueError):
                entrypoint.prepare_auth(data, '12' * 32)
            self.assertEqual(alias.read_bytes(), original)
            self.assertEqual(alias.stat().st_nlink, 2)

    def test_links_and_non_regular_authentication_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory) / 'wallet'
            data.mkdir()
            outside = Path(directory) / 'outside'
            outside.write_bytes(b'unchanged fixture')
            outside.chmod(0o644)
            token = data / 'auth_token'
            token.symlink_to(outside)
            with self.assertRaises(OSError):
                entrypoint.prepare_auth(data, '12' * 32)
            self.assertEqual(outside.read_bytes(), b'unchanged fixture')
            self.assertEqual(stat.S_IMODE(outside.stat().st_mode), 0o644)
            token.unlink()
            os.mkfifo(token, 0o600)
            with self.assertRaises(ValueError):
                entrypoint.prepare_auth(data)
            token.unlink()
            token.mkdir()
            with self.assertRaises(ValueError):
                entrypoint.prepare_auth(data)
            linked = Path(directory) / 'linked-wallet'
            linked.symlink_to(data, target_is_directory=True)
            with self.assertRaises(OSError):
                entrypoint.prepare_auth(linked)

    def test_oversized_noncanonical_or_corrupt_authentication_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory) / 'wallet'
            entrypoint.prepare_auth(data, '12' * 32)
            token = data / 'auth_token'
            for content in (b'A' * 100000, b'\xff' * 44, b'A' * 43, b'B' * 44, b'A' * 44 + b'\n'):
                token.write_bytes(content)
                with self.assertRaises(ValueError):
                    entrypoint.prepare_auth(data, '12' * 32)
                self.assertEqual(token.read_bytes(), content)


if __name__ == '__main__':
    unittest.main()
