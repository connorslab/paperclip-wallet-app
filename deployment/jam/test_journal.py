import json
import os
from pathlib import Path
import tempfile
import unittest

from paperclip_jam.journal import Journal, PaymentConflict


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

    def test_symlink_directory_is_rejected(self):
        link = Path(self.root.name).resolve() / 'link'
        link.symlink_to(self.directory, target_is_directory=True)
        with self.assertRaises(ValueError):
            Journal(link)


if __name__ == '__main__':
    unittest.main()
