import asyncio
from pathlib import Path
import tempfile
import unittest

from paperclip_jam.journal import Journal, PaymentConflict
from paperclip_jam.payments import Payments


class Adapter:
    identity = 'xbt:fixture'
    def __init__(self):
        self.authorized = True
        self.prepare_count = 0
        self.send_count = 0
        self.observed = False
        self.timeout = False
        self.inputs_valid = True
        self.after_build = None

    def authorize(self):
        if not self.authorized:
            raise PermissionError('Session ended')

    async def prepare(self, request):
        self.prepare_count += 1
        if self.after_build:
            self.after_build()
        return {'txid': '2' * 64, 'amount_sat': request['amount_sat'], 'fee_sat': 100}, 'aabb'

    async def validate_inputs(self, quote):
        if not self.inputs_valid:
            raise PaymentConflict('Selected coins changed')

    async def broadcast(self, signed, quote):
        self.send_count += 1
        if self.timeout:
            raise TimeoutError('Synthetic lost response')
        return '2' * 64

    async def observe(self, quote):
        return self.observed


class PaymentsTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.journal = Journal(Path(self.root.name).resolve() / 'private')
        self.service = Payments(self.journal)
        self.adapter = Adapter()
        self.identifier = '1' * 64
        self.request = {'amount_sat': 1000}

    def tearDown(self):
        self.journal.close()
        self.root.cleanup()

    async def test_prepare_is_not_send_and_same_id_is_not_rebuilt(self):
        review = await self.service.prepare(self.adapter, self.identifier, self.request)
        self.assertEqual(await self.service.prepare(self.adapter, self.identifier, self.request), review)
        self.assertEqual(self.adapter.prepare_count, 1)
        self.assertEqual(self.adapter.send_count, 0)
        result = await self.service.commit(self.adapter, self.identifier, review['approval'])
        self.assertEqual(result['state'], 'submitted')
        await self.service.commit(self.adapter, self.identifier, review['approval'])
        self.assertEqual(self.adapter.send_count, 1)

    async def test_lost_response_can_only_be_observed(self):
        review = await self.service.prepare(self.adapter, self.identifier, self.request)
        self.adapter.timeout = True
        with self.assertRaises(TimeoutError):
            await self.service.commit(self.adapter, self.identifier, review['approval'])
        self.assertEqual((await self.service.check(self.adapter, self.identifier))['state'], 'unknown')
        await self.service.commit(self.adapter, self.identifier, review['approval'])
        with self.assertRaises(PaymentConflict):
            await self.service.cancel(self.adapter, self.identifier)
        self.assertEqual(self.adapter.send_count, 1)
        self.adapter.observed = True
        self.assertEqual((await self.service.check(self.adapter, self.identifier))['state'], 'submitted')
        self.assertEqual(self.adapter.send_count, 1)

    async def test_concurrent_commits_broadcast_once(self):
        review = await self.service.prepare(self.adapter, self.identifier, self.request)
        results = await asyncio.gather(*[self.service.commit(self.adapter, self.identifier, review['approval']) for _ in range(2)])
        self.assertEqual(self.adapter.send_count, 1)
        self.assertTrue(all(result['state'] == 'submitted' for result in results))

    async def test_changed_coins_or_revoked_session_prevent_broadcast(self):
        review = await self.service.prepare(self.adapter, self.identifier, self.request)
        self.adapter.inputs_valid = False
        with self.assertRaises(PaymentConflict):
            await self.service.commit(self.adapter, self.identifier, review['approval'])
        self.adapter.inputs_valid = True
        self.adapter.authorized = False
        with self.assertRaises(PermissionError):
            await self.service.commit(self.adapter, self.identifier, review['approval'])
        self.assertEqual(self.adapter.send_count, 0)

    async def test_lock_during_preparation_invalidates_quote(self):
        self.adapter.after_build = lambda: setattr(self.adapter, 'authorized', False)
        with self.assertRaises(PermissionError):
            await self.service.prepare(self.adapter, self.identifier, self.request)
        self.assertEqual(self.journal.status(self.adapter.identity, self.identifier)['state'], 'cancelled')
        self.assertEqual(self.adapter.send_count, 0)


if __name__ == '__main__':
    unittest.main()
