"""Exercise actual upstream CoinJoin input reservations on native Windows.

All outpoints are synthetic; no node, wallet key or payment is used.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib.util
from pathlib import Path
import sys
import tempfile
import threading
from types import ModuleType
import unittest
from unittest.mock import patch as mock_patch

import win32security

from install_windows_utxo_metadata import patch
from paperclip_jam import windows_storage

UPSTREAM = None


class UTXOMetadata(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'utxo_metadata.py'
        self.source.write_bytes(UPSTREAM.read_bytes())
        patch(self.source)
        spec = importlib.util.spec_from_file_location('reviewed_utxo_metadata', self.source)
        self.api = importlib.util.module_from_spec(spec)
        with mock_patch.dict(sys.modules, {'jmcore':ModuleType('jmcore'), 'jmcore.secure_files':windows_storage, spec.name:self.api}):
            spec.loader.exec_module(self.api)
        self.path = self.root / 'private' / 'utxos.jsonl'
        self.outpoint = 'a' * 64 + ':0'

    def store(self):
        return self.api.UTXOMetadataStore(path=self.path)

    def test_parallel_rounds_cannot_reserve_the_same_input(self):
        barrier=threading.Barrier(2)
        def reserve(owner):
            store=self.store();barrier.wait(timeout=5)
            return owner,store.try_lock_outpoints([self.outpoint],owner=owner)
        with ThreadPoolExecutor(max_workers=2) as pool:
            outcomes=list(pool.map(reserve,['round-a','round-b']))
        winners=[owner for owner,success in outcomes if success]
        self.assertEqual(len(winners),1)
        reopened=self.store();reopened.load()
        self.assertEqual(reopened.records[self.outpoint].lock_owner,winners[0])
        self.assertFalse(reopened.try_lock_outpoints([self.outpoint],owner='third'))

    def test_wrong_owner_cannot_release_or_renew_after_reopen(self):
        first=self.store();self.assertTrue(first.try_lock_outpoints([self.outpoint],owner='round-a'))
        second=self.store()
        self.assertFalse(second.renew_outpoints([self.outpoint],owner='round-b'))
        second.release_outpoints([self.outpoint],owner='round-b')
        self.assertFalse(second.try_lock_outpoints([self.outpoint],owner='round-b'))
        second.release_outpoints([self.outpoint],owner='round-a')
        self.assertTrue(second.try_lock_outpoints([self.outpoint],owner='round-b'))
        first.release_outpoints([self.outpoint],owner='round-a')
        final=self.store();final.load()
        self.assertEqual(final.records[self.outpoint].lock_owner,'round-b')

    def test_unsafe_sidecar_cannot_be_repaired_or_admit_another_round(self):
        store=self.store();self.assertTrue(store.try_lock_outpoints([self.outpoint],owner='round-a'))
        before=windows_storage.read_sensitive_file(self.path)
        lock=store._flock_path
        win32security.SetNamedSecurityInfo(str(lock),win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION,None,None,None,None)
        with self.assertRaises(ValueError):
            self.store().release_outpoints([self.outpoint],owner='round-a')
        self.assertEqual(windows_storage.read_sensitive_file(self.path),before)
        self.assertIsNone(win32security.GetNamedSecurityInfo(str(lock),win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION).GetSecurityDescriptorDacl())

    def test_changed_upstream_is_rejected_without_modification(self):
        original=UPSTREAM.read_bytes()+b'\n# changed\n';self.source.write_bytes(original)
        with self.assertRaises(ValueError):patch(self.source)
        self.assertEqual(self.source.read_bytes(),original)


if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--upstream',type=Path,required=True)
    args,remaining=parser.parse_known_args();UPSTREAM=args.upstream.resolve(strict=True)
    unittest.main(argv=[__file__]+remaining)
