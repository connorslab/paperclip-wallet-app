"""Native owned-entry prerequisites, without importing the Jars crypto runtime."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import win32api
import win32security

from windows.private_storage import atomic_write_private

SOURCE = Path(__file__).resolve().parents[2] / 'jam' / 'desktop-entry.py'


class Entry(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name).resolve()/'parent'/'jars'
        spec=importlib.util.spec_from_file_location('reviewed_jars_entry',SOURCE)
        self.api=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.api)
        self.api.private_directory(self.root)

    def test_untrusted_environment_cannot_select_another_wallet_or_tls_mode(self):
        with patch.dict(os.environ,{'SystemRoot':'Z:/untrusted','JOINMARKET_DATA_DIR':'Z:/other',
                'JMWALLETD_NO_TLS':'1','HTTPS_PROXY':'http://127.0.0.1:1','PYTHONPATH':'Z:/untrusted',
                'PATH':'Z:/untrusted'},clear=True):
            environment=self.api.runtime_environment(self.root)
        self.assertEqual(environment['SystemRoot'],win32api.GetWindowsDirectory())
        self.assertEqual(environment['JOINMARKET_DATA_DIR'],str(self.root))
        self.assertEqual(environment['PATH'],str(Path(win32api.GetWindowsDirectory())/'System32'))
        for key in ['JMWALLETD_NO_TLS','HTTPS_PROXY','PYTHONPATH']:self.assertNotIn(key,environment)
        self.api.private_directory(Path(environment['TEMP']))

    def test_entry_lock_excludes_competing_startup_and_releases_after_error(self):
        with self.api.entry_lock(self.root):
            with self.assertRaises(BlockingIOError):
                with self.api.entry_lock(self.root):self.fail('Concurrent child admitted')
        with self.assertRaisesRegex(RuntimeError,'fixture'):
            with self.api.entry_lock(self.root):raise RuntimeError('fixture')
        with self.api.entry_lock(self.root):pass

    def test_tls_material_must_be_private_and_permissions_are_not_repaired(self):
        path=self.root/'public-fixture.pem';atomic_write_private(path,b'public synthetic certificate bytes')
        self.api.private_file(path)
        win32security.SetNamedSecurityInfo(str(path),win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION,None,None,None,None)
        with self.assertRaises(ValueError):self.api.private_file(path)
        self.assertIsNone(win32security.GetNamedSecurityInfo(str(path),win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION).GetSecurityDescriptorDacl())


if __name__ == '__main__':unittest.main()
