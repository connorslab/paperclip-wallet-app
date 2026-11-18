"""Pinned Jam history API against native Windows private files; synthetic records."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib.util
from pathlib import Path
import sys
import tempfile
from types import ModuleType
import unittest
from unittest.mock import patch as mock_patch

import win32security

from install_windows_history import patch
from paperclip_jam import windows_storage

UPSTREAM = None


class History(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name).resolve();self.data=self.root/'private'
        self.source=self.root/'history.py';self.source.write_bytes(UPSTREAM.read_bytes());patch(self.source)
        spec=importlib.util.spec_from_file_location('reviewed_jam_history',self.source)
        self.api=importlib.util.module_from_spec(spec)
        paths=ModuleType('jmcore.paths');paths.get_default_data_dir=lambda:self.data
        with mock_patch.dict(sys.modules,{'jmcore':ModuleType('jmcore'),'jmcore.paths':paths,spec.name:self.api}):
            spec.loader.exec_module(self.api)

    def entry(self,n):
        return self.api.TransactionHistoryEntry(timestamp=f'2026-01-01T00:00:{n:02d}+00:00',role='send',success=False,
            txid=f'{n:064x}',amount=1000+n,wallet_fingerprint='12345678',failure_reason='Unconfirmed synthetic send')

    def test_append_reopen_and_atomic_rewrite_preserve_uncertain_outcomes(self):
        self.api.append_history_entry(self.entry(2),self.data)
        self.api.append_history_entry(self.entry(1),self.data)
        path=self.api._get_history_path(self.data)
        rows=self.api._read_history_entries_unlocked(path)
        self.assertEqual(len(rows),2)
        with self.api._history_lock(path):
            self.assertTrue(self.api._write_history_entries_atomic(rows,path))
        rows=self.api._read_history_entries_unlocked(path)
        self.assertEqual([r.amount for r in rows],[1001,1002])
        self.assertTrue(all(not r.success and r.failure_reason=='Unconfirmed synthetic send' for r in rows))
        windows_storage.ensure_private_file(path)
        self.assertFalse(list(self.data.glob('*.tmp')))

    def test_parallel_appends_keep_every_record(self):
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda n:self.api.append_history_entry(self.entry(n),self.data),range(1,9)))
        rows=self.api._read_history_entries_unlocked(self.api._get_history_path(self.data))
        self.assertEqual(len(rows),8)
        self.assertEqual({r.txid for r in rows},{f'{n:064x}' for n in range(1,9)})

    def test_legacy_filename_migrates_under_owned_lock(self):
        self.api.append_history_entry(self.entry(1),self.data)
        path=self.api._get_history_path(self.data)
        legacy=path.with_name(self.api.LEGACY_HISTORY_FILENAME);path.rename(legacy)
        self.api.append_history_entry(self.entry(2),self.data)
        self.assertFalse(legacy.exists())
        self.assertEqual(len(self.api._read_history_entries_unlocked(path)),2)

    def test_unsafe_history_cannot_be_read_appended_or_replaced(self):
        self.api.append_history_entry(self.entry(1),self.data)
        path=self.api._get_history_path(self.data);before=path.read_bytes()
        win32security.SetNamedSecurityInfo(str(path),win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION,None,None,None,None)
        with self.assertRaises(self.api.HistoryWriteError):
            self.api.append_history_entry(self.entry(2),self.data)
        with self.assertRaises(self.api.HistoryWriteError):
            self.api._open_owner_only_regular(path,0)
        self.assertFalse(self.api._write_history_entries_atomic([self.entry(2)],path))
        self.assertEqual(path.read_bytes(),before)
        self.assertIsNone(win32security.GetNamedSecurityInfo(str(path),win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION).GetSecurityDescriptorDacl())

    def test_wrong_source_hash_is_rejected(self):
        original=UPSTREAM.read_bytes()+b'\n# changed\n';self.source.write_bytes(original)
        with self.assertRaises(ValueError):patch(self.source)
        self.assertEqual(self.source.read_bytes(),original)


if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--upstream',type=Path,required=True)
    args,remaining=parser.parse_known_args();UPSTREAM=args.upstream.resolve(strict=True)
    unittest.main(argv=[__file__]+remaining)
