import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from paperclip_jam.journal import Journal, PaymentConflict

if os.name == 'nt':
    import win32file
    import win32security
    from windows.private_storage import private_directory, read_private_file, writable_private_file


class JournalTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.now = 1000
        self.directory = Path(self.root.name).resolve() / 'private'
        self.journal = Journal(self.directory, lambda: self.now)
        self.identifier = '1' * 64
        self.wallet = 'xbt:fixture-fingerprint'
        self.request = {'jar': 0, 'destination': 'fixture', 'amount_sat': 1000}

    def tearDown(self):
        self.journal.close()
        self.root.cleanup()

    def prepare(self):
        self.assertTrue(self.journal.reserve(self.wallet, self.identifier, self.request))
        return self.journal.prepared(self.wallet, self.identifier,
                                    {'txid': '2' * 64, 'amount_sat': 1000, 'fee_sat': 123}, 'aabb')

    def test_restart_at_submission_boundary_cannot_replay(self):
        review = self.prepare()
        self.assertEqual(self.journal.claim(self.wallet, self.identifier, review['approval']), 'aabb')
        self.journal.close()
        self.journal = Journal(self.directory, lambda: self.now)
        self.assertIsNone(self.journal.claim(self.wallet, self.identifier, review['approval']))
        self.assertTrue(self.journal.pending())
        with self.assertRaises(PaymentConflict):
            self.journal.reserve(self.wallet, '3' * 64, self.request)
        with self.assertRaises(PaymentConflict):
            self.journal.cancel(self.wallet, self.identifier)
        self.journal.finish(self.wallet, self.identifier, False)
        self.assertEqual(self.journal.status(self.wallet, self.identifier)['state'], 'unknown')
        self.assertIsNone(self.journal.claim(self.wallet, self.identifier, review['approval']))
        self.journal.finish(self.wallet, self.identifier, True)
        self.assertFalse(self.journal.pending())
        self.assertIsNone(self.journal.claim(self.wallet, self.identifier, review['approval']))

    def test_idempotent_prepare_and_wallet_request_binding(self):
        self.prepare()
        self.assertFalse(self.journal.reserve(self.wallet, self.identifier, self.request))
        for wallet, request in [('other', self.request), (self.wallet, {**self.request, 'amount_sat': 2000})]:
            with self.assertRaises(PaymentConflict):
                self.journal.reserve(wallet, self.identifier, request)
        with self.assertRaises(PaymentConflict):
            self.journal.status('other', self.identifier)

    def test_expired_cancelled_and_changed_reviews_cannot_submit(self):
        review = self.prepare()
        with self.assertRaises(PaymentConflict):
            self.journal.claim(self.wallet, self.identifier, 'wrong')
        self.now = review['expires']
        with self.assertRaises(PaymentConflict):
            self.journal.claim(self.wallet, self.identifier, review['approval'])
        self.journal.cancel(self.wallet, self.identifier)
        self.assertFalse(self.journal.pending())
        self.now = 1000
        with self.assertRaises(PaymentConflict):
            self.journal.claim(self.wallet, self.identifier, review['approval'])

    def test_disk_failure_cannot_cross_submission_boundary(self):
        review = self.prepare()
        self.journal.db.execute('PRAGMA query_only=ON')
        with self.assertRaises(Exception):
            self.journal.claim(self.wallet, self.identifier, review['approval'])
        self.assertEqual(self.journal.status(self.wallet, self.identifier)['state'], 'prepared')
        self.journal.db.execute('PRAGMA query_only=OFF')
        self.assertEqual(self.journal.claim(self.wallet, self.identifier, review['approval']), 'aabb')

    def test_corrupted_transaction_cannot_submit(self):
        review = self.prepare()
        self.journal.db.execute("UPDATE payment SET signed_tx='aabc'")
        with self.assertRaises(PaymentConflict):
            self.journal.claim(self.wallet, self.identifier, review['approval'])

    def test_private_material_never_appears_in_status(self):
        review = self.prepare()
        self.assertNotIn('aabb', json.dumps(review))
        self.assertNotIn('signed_tx', review)
        if os.name == 'nt':
            private_directory(self.directory)
            for name in ('payments.sqlite', 'payments.sqlite-journal'):
                with read_private_file(self.directory / name):
                    pass  # Checked native owner/ACL, type and link count.
        else:
            self.assertEqual(os.stat(self.directory).st_mode & 0o777, 0o700)
            self.assertEqual(os.stat(self.directory / 'payments.sqlite').st_mode & 0o777, 0o600)

    def test_second_connection_cannot_claim_same_payment(self):
        review = self.prepare()
        other = Journal(self.directory, lambda: self.now)
        try:
            self.assertEqual(other.claim(self.wallet, self.identifier, review['approval']), 'aabb')
            self.assertIsNone(self.journal.claim(self.wallet, self.identifier, review['approval']))
        finally:
            other.close()

    def crash_writer(self, operation):
        # A new interpreter exits without closing SQLite or running finally
        # blocks. No socket, wallet key, payment or external service is used.
        program = '''
import os
import sys
from paperclip_jam.journal import Journal
journal = Journal(sys.argv[1], lambda: 1000)
wallet, identifier = 'xbt:fixture-fingerprint', '1' * 64
review = journal.status(wallet, identifier)
if sys.argv[2] == 'claimed':
    assert journal.claim(wallet, identifier, review['approval']) == 'aabb'
else:
    journal.db.execute('PRAGMA cache_size=5')
    journal.db.execute('BEGIN IMMEDIATE')
    journal.db.execute("UPDATE payment SET state='submitting' WHERE id=?", (identifier,))
    if sys.argv[2] == 'uncommitted-spill':
        journal.db.execute("UPDATE payment SET signed_tx=? WHERE id=?", ('aa' * 100000, identifier))
os._exit(23)
'''
        result = subprocess.run([sys.executable, '-c', program, str(self.directory), operation],
                                capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 23, 'Crash fixture did not reach its exit boundary')
        self.assertEqual(result.stdout, b'')
        self.assertEqual(result.stderr, b'')

    def test_abrupt_exit_after_claim_and_backup_restore_cannot_replay(self):
        review = self.prepare()
        self.crash_writer('claimed')
        self.assertEqual(self.journal.status(self.wallet, self.identifier)['state'], 'submitting')
        self.assertIsNone(self.journal.claim(self.wallet, self.identifier, review['approval']))
        # This is a quiescent journal copy, not a full host-volume backup test.
        restored_directory = self.directory.parent / 'restored'
        if os.name == 'nt':
            # Restore bytes into private Windows files, not chmod-only copies
            # whose default owner can be a group under an elevated token.
            private_directory(restored_directory)
            for source in self.directory.iterdir():
                with read_private_file(source) as reader, writable_private_file(restored_directory / source.name) as target:
                    data = reader.read()
                    if data:
                        self.assertEqual(win32file.WriteFile(target, data)[1], len(data))
                    win32file.FlushFileBuffers(target)
        else:
            shutil.copytree(self.directory, restored_directory)
        restored = Journal(restored_directory, lambda: self.now)
        try:
            self.assertTrue(restored.pending())
            self.assertIsNone(restored.claim(self.wallet, self.identifier, review['approval']))
            with self.assertRaises(PaymentConflict):
                restored.cancel(self.wallet, self.identifier)
            with self.assertRaises(PaymentConflict):
                restored.reserve(self.wallet, '3' * 64, self.request)
            restored.finish(self.wallet, self.identifier, False)
            self.assertEqual(restored.status(self.wallet, self.identifier)['state'], 'unknown')
            restored.finish(self.wallet, self.identifier, True)
            self.assertFalse(restored.pending())
            self.assertIsNone(restored.claim(self.wallet, self.identifier, review['approval']))
        finally:
            restored.close()

    def test_abrupt_exit_before_commit_rolls_back_submission_boundary(self):
        review = self.prepare()
        self.crash_writer('uncommitted')
        self.assertEqual(self.journal.status(self.wallet, self.identifier)['state'], 'prepared')
        self.assertEqual(self.journal.claim(self.wallet, self.identifier, review['approval']), 'aabb')
        self.assertIsNone(self.journal.claim(self.wallet, self.identifier, review['approval']))

    def test_abrupt_exit_after_cache_spill_recovers_the_original_review(self):
        review = self.prepare()
        self.crash_writer('uncommitted-spill')
        self.assertEqual(self.journal.status(self.wallet, self.identifier)['state'], 'prepared')
        self.assertEqual(self.journal.claim(self.wallet, self.identifier, review['approval']), 'aabb')
        self.assertIsNone(self.journal.claim(self.wallet, self.identifier, review['approval']))

    @unittest.skipUnless(os.name == 'nt', 'Native Windows storage contract')
    def test_open_database_and_active_rollback_cannot_be_replaced(self):
        review = self.prepare()
        database = self.directory / 'payments.sqlite'
        rollback = self.directory / 'payments.sqlite-journal'
        with self.assertRaises(OSError):
            database.rename(self.directory / 'moved.sqlite')
        with self.journal.transaction():
            with self.assertRaises(OSError):
                rollback.unlink()
        self.assertEqual(self.journal.claim(self.wallet, self.identifier, review['approval']), 'aabb')

    @unittest.skipUnless(os.name == 'nt', 'Native Windows storage contract')
    def test_changed_rollback_permissions_cannot_cross_submission_boundary(self):
        review = self.prepare()
        rollback = self.directory / 'payments.sqlite-journal'
        win32security.SetNamedSecurityInfo(str(rollback), win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION, None, None, None, None)
        with self.assertRaises(ValueError):
            self.journal.claim(self.wallet, self.identifier, review['approval'])
        self.assertEqual(self.journal.status(self.wallet, self.identifier)['state'], 'prepared')
        descriptor = win32security.GetNamedSecurityInfo(str(rollback), win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION)
        self.assertIsNone(descriptor.GetSecurityDescriptorDacl())

    @unittest.skipUnless(os.name == 'nt', 'Native Windows storage contract')
    def test_unexpected_wal_file_is_rejected_without_modification(self):
        review = self.prepare()
        self.journal.close()
        sidecar = self.directory / 'payments.sqlite-wal'
        marker = b'unreviewed-storage-mode'
        with writable_private_file(sidecar) as handle:
            self.assertEqual(win32file.WriteFile(handle, marker)[1], len(marker))
            win32file.FlushFileBuffers(handle)
        with self.assertRaises(ValueError):
            Journal(self.directory)
        with read_private_file(sidecar) as reader:
            self.assertEqual(reader.read(), marker)
        sidecar.unlink()
        self.journal = Journal(self.directory, lambda: self.now)
        self.assertEqual(self.journal.claim(self.wallet, self.identifier, review['approval']), 'aabb')

    def test_symlink_directory_is_rejected(self):
        link = Path(self.root.name).resolve() / 'link'
        if os.name == 'nt':
            result = subprocess.run(['cmd', '/C', 'mklink', '/J', str(link), str(self.directory)],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.assertEqual(result.returncode, 0)
        else:
            link.symlink_to(self.directory, target_is_directory=True)
        try:
            with self.assertRaises(ValueError):
                Journal(link)
        finally:
            if os.name == 'nt':
                link.rmdir()
            else:
                link.unlink()


if __name__ == '__main__':
    unittest.main()
