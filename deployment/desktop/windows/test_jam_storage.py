"""Exercise the patched, pinned upstream file API on native Windows."""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

import win32security

from install_windows_storage import patch
from windows.private_storage import read_private_file

UPSTREAM = None


class JamStorage(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        source = self.root / 'secure_files.py'
        source.write_bytes(UPSTREAM.read_bytes())
        patch(source)
        spec = importlib.util.spec_from_file_location('reviewed_upstream_secure_files', source)
        self.api = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.api)
        self.private = self.root / 'private'
        self.api.ensure_private_directory(self.private)

    def test_actual_upstream_api_creates_and_replaces_checked_private_bytes(self):
        path = self.private / 'nested' / 'wallet.dat'
        self.api.create_private_file_exclusive(path, b'original-fixture')
        self.api.ensure_private_file(path)
        self.assertEqual(self.api.read_private_file(path), b'original-fixture')
        with read_private_file(path) as old:
            self.api.atomic_write_private(path, b'new-fixture')
            self.assertEqual(old.read(), b'original-fixture')
        self.assertEqual(self.api.read_private_file(path), b'new-fixture')
        self.assertEqual(list(path.parent.iterdir()), [path])

    def test_config_and_metadata_api_require_the_same_private_storage(self):
        path = self.private / 'config' / 'settings.toml'
        self.api.ensure_sensitive_directory(path.parent)
        self.api.atomic_write_sensitive_file(path, b'fixture = true')
        self.api.ensure_sensitive_file(path)
        self.assertEqual(self.api.read_sensitive_file(path), b'fixture = true')
        win32security.SetNamedSecurityInfo(str(path), win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION, None, None, None, None)
        for operation in (self.api.ensure_sensitive_file, self.api.read_sensitive_file):
            with self.assertRaises(ValueError):
                operation(path)
        with self.assertRaises(ValueError):
            self.api.atomic_write_sensitive_file(path, b'changed = true')
        self.assertEqual(path.read_bytes(), b'fixture = true')
        self.assertIsNone(win32security.GetNamedSecurityInfo(str(path), win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION).GetSecurityDescriptorDacl())

    def test_exclusive_upstream_create_never_overwrites_a_wallet(self):
        path = self.private / 'wallet.dat'
        self.api.create_private_file_exclusive(path, b'original-fixture')
        with self.assertRaises(FileExistsError):
            self.api.create_private_file_exclusive(path, b'retry-fixture')
        self.assertEqual(self.api.read_private_file(path), b'original-fixture')

    def test_parent_traversal_cannot_create_or_rewrite_storage(self):
        path = self.private / '..' / 'unexpected' / 'wallet.dat'
        for operation in (self.api.atomic_write_private, self.api.create_private_file_exclusive):
            with self.assertRaises(ValueError):
                operation(path, b'fixture')
        self.assertFalse((self.root / 'unexpected').exists())

    def test_config_alias_is_rejected_without_following_junction(self):
        link = self.root / 'alias'
        result = subprocess.run(['cmd', '/C', 'mklink', '/J', str(link), str(self.private)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertEqual(result.returncode, 0)
        try:
            with self.assertRaises(ValueError):
                self.api.atomic_write_sensitive_file(link / 'config.toml', b'fixture')
            self.assertFalse((self.private / 'config.toml').exists())
        finally:
            link.rmdir()

    def test_unreviewed_upstream_is_rejected_without_modification(self):
        source = self.root / 'unreviewed.py'
        original = UPSTREAM.read_bytes() + b'\n# unreviewed change\n'
        source.write_bytes(original)
        with self.assertRaises(ValueError):
            patch(source)
        self.assertEqual(source.read_bytes(), original)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--upstream', type=Path, required=True)
    args, remaining = parser.parse_known_args()
    UPSTREAM = args.upstream.resolve(strict=True)
    unittest.main(argv=[__file__] + remaining)
