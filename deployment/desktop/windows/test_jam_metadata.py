"""Actual pinned identity/metadata API with private native Windows storage.

Synthetic public identities only: no mnemonic, keys or wallet creation.
"""
import argparse
import importlib.util
from pathlib import Path
import sys
import tempfile
import threading
from types import ModuleType
import unittest
from unittest.mock import patch as mock_patch

import win32security

from install_windows_metadata import patch
from paperclip_jam import windows_storage

UPSTREAM = None


class Metadata(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'wallet_metadata.py'
        self.source.write_bytes(UPSTREAM.read_bytes())
        patch(self.source)
        spec = importlib.util.spec_from_file_location('reviewed_wallet_metadata', self.source)
        self.api = importlib.util.module_from_spec(spec)
        # Import the actual metadata module with the reviewed native file API;
        # jmcore package initialization otherwise pulls unrelated crypto binaries.
        with mock_patch.dict(sys.modules, {'jmcore':ModuleType('jmcore'), 'jmcore.secure_files':windows_storage, spec.name:self.api}):
            spec.loader.exec_module(self.api)
        self.wallet = self.root / 'private' / 'wallet.jmdat'
        windows_storage.ensure_private_directory(self.wallet.parent)

    def identity(self, fingerprint='12345678', bip39='none'):
        return self.api.WalletIdentity(fingerprint=fingerprint, bip39=bip39)

    def test_registration_preserves_selection_and_unknown_recovery_metadata(self):
        self.api.write_mnemonic_meta(self.wallet, {'recovery':{'state':'uncertain'}, 'future':'keep'})
        self.assertTrue(self.api.register_identity(self.wallet,self.identity()))
        self.assertFalse(self.api.register_identity(self.wallet,self.identity('87654321','required')))
        self.assertEqual(self.api.selected_identity(self.wallet).fingerprint,'12345678')
        self.api.select_identity(self.wallet,'87654321')
        self.assertEqual(self.api.selected_identity(self.wallet).bip39,'required')
        meta=self.api.load_mnemonic_meta(self.wallet,strict=True)
        self.assertEqual(meta['recovery'],{'state':'uncertain'})
        self.assertEqual(meta['future'],'keep')

    def test_corrupt_metadata_never_becomes_a_new_registration(self):
        path=self.api.meta_path(self.wallet)
        windows_storage.atomic_write_private(path,b'{broken')
        with self.assertRaises(ValueError):
            self.api.register_identity(self.wallet,self.identity())
        self.assertEqual(windows_storage.read_private_file(path),b'{broken')

    def test_foreign_legacy_fingerprint_cannot_be_adopted(self):
        self.api.write_mnemonic_meta(self.wallet,{'fingerprint':'87654321','recovery':'keep'})
        self.assertFalse(self.api.adopt_legacy_identity(self.wallet,self.identity()))
        self.assertTrue(self.api.adopt_legacy_identity(self.wallet,self.identity('87654321')))
        self.assertEqual(self.api.load_mnemonic_meta(self.wallet,strict=True)['recovery'],'keep')

    def test_recovery_reservation_is_nonblocking_and_survives_failure(self):
        with self.api.metadata_lock(self.wallet,nonblocking=True):
            with self.assertRaises(BlockingIOError):
                with self.api.metadata_lock(self.wallet,nonblocking=True):
                    self.fail('Concurrent recovery admitted')
        with self.api.metadata_lock(self.wallet,nonblocking=True):
            pass

    def test_regular_metadata_writer_waits_for_current_owner(self):
        started, entered, finished = threading.Event(),threading.Event(),threading.Event()
        errors=[]
        def writer():
            started.set()
            try:
                with self.api.metadata_lock(self.wallet):
                    entered.set()
            except BaseException as error:
                errors.append(error)
            finally:
                finished.set()
        with self.api.metadata_lock(self.wallet):
            thread=threading.Thread(target=writer,daemon=True);thread.start()
            self.assertTrue(started.wait(5))
            self.assertFalse(entered.wait(.2))
        self.assertTrue(finished.wait(5))
        thread.join(timeout=1)
        self.assertEqual(errors,[])
        self.assertTrue(entered.is_set())

    def test_unsafe_metadata_is_rejected_without_permission_repair(self):
        self.api.write_mnemonic_meta(self.wallet,{'future':'keep'})
        path=self.api.meta_path(self.wallet)
        win32security.SetNamedSecurityInfo(str(path),win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION,None,None,None,None)
        with self.assertRaises(ValueError):
            self.api.register_identity(self.wallet,self.identity())
        self.assertEqual(path.read_text(),'{\n  "future": "keep"\n}\n')
        self.assertIsNone(win32security.GetNamedSecurityInfo(str(path),win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION).GetSecurityDescriptorDacl())

    def test_unreviewed_source_is_not_modified(self):
        original=UPSTREAM.read_bytes()+b'\n# changed\n';self.source.write_bytes(original)
        with self.assertRaises(ValueError):patch(self.source)
        self.assertEqual(self.source.read_bytes(),original)


if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--upstream',type=Path,required=True)
    args,remaining=parser.parse_known_args();UPSTREAM=args.upstream.resolve(strict=True)
    unittest.main(argv=[__file__]+remaining)
