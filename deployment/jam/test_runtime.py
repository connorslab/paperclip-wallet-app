"""Real pinned Jam signer and HTTP routes, with an unfunded synthetic chain.

Run in the pinned dependency environment after applying install.py. No node,
production credentials or externally funded wallet is accessed by these tests.
"""
import asyncio
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient
from loguru import logger
from mnemonic import Mnemonic
from jmcore.bitcoin import get_txid
from jmwallet.backends.base import Transaction
from jmwallet.wallet.address import pubkey_to_p2wpkh_script
from jmwallet.wallet.models import UTXOInfo
from jmwallet.wallet.service import WalletService
from jmwalletd.app import create_app
from jmwalletd.deps import get_daemon_state

from paperclip_jam.adapter import JamAdapter


class RuntimeTest(unittest.TestCase):
    def setUp(self):
        logger.remove()  # Synthetic keys and token material must not reach test logs.
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name).resolve()
        self.backend = AsyncMock()
        self.backend.get_block_height.return_value = 200
        self.backend.get_median_time_past.return_value = 1_800_000_000
        self.backend.broadcast_transaction.side_effect = lambda raw: get_txid(raw)
        self.wallet = WalletService(Mnemonic('english').to_mnemonic(bytes(32)),
            self.backend, network='regtest', data_dir=self.directory, scan_range=10)
        self.wallet.sync_with_registered_bonds = AsyncMock()
        self.wallet.utxo_cache = {jar: [] for jar in range(5)}
        address = self.wallet.get_receive_address(0, 0)
        key = self.wallet.get_key_for_address(address)
        self.coin = UTXOInfo(txid='1' * 64, vout=0, value=100_000,
            address=address, confirmations=10,
            scriptpubkey=pubkey_to_p2wpkh_script(key.get_public_key_bytes().hex()).hex(),
            path="m/84'/1'/0'/0/0", mixdepth=0)
        self.wallet.utxo_cache[0] = [self.coin]
        self.backend.get_utxo.return_value = self.coin
        self.app = create_app(data_dir=self.directory)
        self.assertTrue(hasattr(self.app.state, 'paperclip_payments'), 'Patch the pinned runtime before testing')
        self.state = get_daemon_state()
        self.state.wallet_service = self.wallet
        self.state.wallet_name = 'fixture.jmdat'
        self.token = self.state.token_authority.issue(self.state.wallet_name).token
        self.client = TestClient(self.app, raise_server_exceptions=True)
        self.client.headers['Authorization'] = 'Bearer ' + self.token
        self.backend_patch = patch('paperclip_jam.adapter.get_backend', AsyncMock(return_value=self.backend))
        self.backend_patch.start()
        self.base = '/api/v1/wallet/fixture.jmdat/paperclip/payments'
        self.body = {'id': 'a' * 64, 'purpose': 'send', 'jar': 0,
            'destination': self.wallet.get_receive_address(1, 0),
            'amount_sat': 20_000, 'send_max': False, 'fee_rate_millisat_vb': 1000,
            'max_fee_sat': 1000, 'max_total_sat': 21_000, 'rbf': False,
            'input_utxos': [self.coin.outpoint]}

    def tearDown(self):
        self.backend_patch.stop()
        self.client.close()
        self.app.state.paperclip_payments.journal.close()
        self.temp.cleanup()

    def prepare(self):
        response = self.client.post(self.base, json=self.body)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def test_pairing_identity_is_authenticated_and_survives_pending_review(self):
        target = self.base.replace('/payments', '/identity')
        expected = {'wallet': 'fixture.jmdat', 'identity': JamAdapter(self.state, self.token, 'fixture.jmdat').identity}
        self.assertEqual(self.client.get(target).json(), expected)
        self.prepare()
        self.assertEqual(self.client.get(target).json(), expected)
        self.assertNotEqual(self.client.get(target.replace('fixture.jmdat', 'other.jmdat')).status_code, 200)
        self.client.headers['Authorization'] = 'Bearer invalid-fixture'
        self.assertEqual(self.client.get(target).status_code, 401)
        self.backend.broadcast_transaction.assert_not_awaited()

    def test_host_delegation_is_scoped_and_independent_of_short_jwt_expiry(self):
        import jwt
        target = self.base.replace('/payments', '/pairing-session')
        result = self.client.post(target, json={})
        self.assertEqual(result.status_code, 200)
        delegation = result.json()['token']
        self.assertTrue(delegation.startswith('pjh1_'))
        expired = jwt.encode({'exp': 1, 'scope': self.state.token_authority.scope}, self.state.token_authority._access_key, algorithm='HS256')
        self.client.headers['Authorization'] = 'Bearer ' + expired
        self.assertEqual(self.client.get('/api/v1/session').status_code, 401)
        self.client.headers['Authorization'] = 'Bearer ' + delegation
        self.assertEqual(self.client.get(self.base.replace('/payments', '/identity')).status_code, 200)
        self.assertEqual(self.client.get(self.base).status_code, 200)
        for method, path in [('POST', target), ('POST', self.base),
                ('POST', self.base + '/' + 'a' * 64 + '/commit'),
                ('POST', self.base + '/' + 'a' * 64 + '/cancel'),
                ('GET', '/api/v1/wallet/fixture.jmdat/seed'),
                ('POST', '/api/v1/wallet/fixture.jmdat/unlock'),
                ('GET', '/api/v1/wallet/all'), ('GET', '/api/v1/wallet/other.jmdat/utxos')]:
            self.assertEqual(self.client.request(method, path).status_code, 401, path)
        self.app.state.paperclip_delegations.record['expires'] = 1
        self.assertEqual(self.client.get(self.base).status_code, 401)
        self.backend.broadcast_transaction.assert_not_awaited()

    def test_host_delegation_is_invalidated_by_wallet_lock_and_session_change(self):
        target = self.base.replace('/payments', '/pairing-session')
        delegation = self.client.post(target, json={}).json()['token']
        self.client.headers['Authorization'] = 'Bearer ' + delegation
        self.state._invalidate_ws_clients()
        self.assertEqual(self.client.get(self.base).status_code, 401)
        self.client.headers['Authorization'] = 'Bearer ' + self.token
        delegation = self.client.post(target, json={}).json()['token']
        self.client.headers['Authorization'] = 'Bearer ' + delegation
        self.assertEqual(self.client.get(self.base).status_code, 200)
        self.state.token_authority.reset()
        self.assertEqual(self.client.get(self.base).status_code, 401)
        self.backend.broadcast_transaction.assert_not_awaited()

    def test_real_signing_review_and_once_only_commit(self):
        review = self.prepare()
        self.assertEqual(review['state'], 'prepared')
        self.assertEqual(review['quote']['amount_sat'], 20_000)
        self.assertGreater(review['quote']['fee_sat'], 0)
        self.assertEqual(review['quote']['total_sat'], 20_000 + review['quote']['fee_sat'])
        self.assertNotIn('signed_tx', review)
        self.backend.broadcast_transaction.assert_not_awaited()
        self.assertEqual(self.prepare(), review)
        commit = self.base + '/' + self.body['id'] + '/commit'
        result = self.client.post(commit, json={'approval': review['approval']})
        self.assertEqual(result.status_code, 200, result.text)
        self.assertEqual(result.json()['state'], 'submitted')
        self.assertEqual(self.client.post(commit, json={'approval': review['approval']}).json()['state'], 'submitted')
        self.backend.broadcast_transaction.assert_awaited_once()
        raw = self.backend.broadcast_transaction.await_args.args[0]
        self.assertEqual(get_txid(raw), review['quote']['txid'])

    def test_frozen_coin_after_review_blocks_broadcast(self):
        review = self.prepare()
        self.coin.frozen = True
        result = self.client.post(self.base + '/' + self.body['id'] + '/commit', json={'approval': review['approval']})
        self.assertEqual(result.status_code, 409)
        self.backend.broadcast_transaction.assert_not_awaited()

    def test_chain_spent_coin_cannot_be_sent_from_stale_cache(self):
        review = self.prepare()
        self.backend.get_utxo.return_value = None
        result = self.client.post(self.base + '/' + self.body['id'] + '/commit', json={'approval': review['approval']})
        self.assertEqual(result.status_code, 409)
        self.backend.broadcast_transaction.assert_not_awaited()

    def test_lost_broadcast_reply_is_reconciled_without_resending(self):
        review = self.prepare()
        captured = []
        async def uncertain(raw):
            captured.append(raw)
            raise TimeoutError('Synthetic lost response')
        self.backend.broadcast_transaction.side_effect = uncertain
        target = self.base + '/' + self.body['id']
        result = self.client.post(target + '/commit', json={'approval': review['approval']})
        self.assertEqual(result.status_code, 504)
        self.backend.get_transaction.return_value = None
        self.assertEqual(self.client.get(target).json()['state'], 'unknown')
        self.assertEqual(self.client.post(target + '/commit', json={'approval': review['approval']}).json()['state'], 'unknown')
        self.assertEqual(self.client.post(target + '/cancel').status_code, 409)
        self.backend.get_transaction.return_value = Transaction(review['quote']['txid'], captured[0], 0)
        self.assertEqual(self.client.get(target).json()['state'], 'submitted')
        self.backend.broadcast_transaction.assert_awaited_once()

    def test_revoked_session_after_input_lookup_cannot_broadcast(self):
        review = self.prepare()
        async def revoke(*args):
            self.state.token_authority.reset()
            return self.coin
        self.backend.get_utxo.side_effect = revoke
        result = self.client.post(self.base + '/' + self.body['id'] + '/commit', json={'approval': review['approval']})
        self.assertEqual(result.status_code, 401)
        self.backend.broadcast_transaction.assert_not_awaited()

    def test_pending_review_blocks_legacy_maker_and_direct_send(self):
        self.prepare()
        for suffix in ('maker/start', 'taker/direct-send', 'taker/coinjoin'):
            result = self.client.post('/api/v1/wallet/fixture.jmdat/' + suffix, json={})
            self.assertEqual(result.status_code, 409, result.text)
        result = self.client.get('/api/v1/wallet/fixture.jmdat/address/new/0')
        self.assertEqual(result.status_code, 409)
        self.assertEqual(self.client.get(self.base).status_code, 200)
        self.assertEqual(self.client.post(self.base + '/' + self.body['id'] + '/cancel').status_code, 200)
        self.assertFalse(self.app.state.paperclip_payments.journal.pending())

    def test_active_maker_blocks_prepare_and_requires_new_review(self):
        self.state.maker_running = True
        self.assertEqual(self.client.post(self.base, json=self.body).status_code, 409)
        self.backend.broadcast_transaction.assert_not_awaited()

    def test_strict_amounts_and_limits(self):
        for field, value in [('amount_sat', True), ('amount_sat', '20000'),
                ('amount_sat', 0), ('fee_rate_millisat_vb', 999), ('jar', 5),
                ('input_utxos', []), ('input_utxos', [self.coin.outpoint] * 2),
                ('purpose', 'withdraw_bond'), ('bond_locktime', 2_000_000_000)]:
            body = {**self.body, field: value}
            self.assertEqual(self.client.post(self.base, json=body).status_code, 422, field)
        self.assertEqual(self.client.post(self.base, json={**self.body, 'max_fee_sat': 1}).status_code, 409)
        self.backend.broadcast_transaction.assert_not_awaited()

    def test_wrong_wallet_or_expired_token_cannot_read_or_commit(self):
        review = self.prepare()
        self.assertNotEqual(self.client.get(self.base.replace('fixture.jmdat', 'other.jmdat')).status_code, 200)
        self.client.headers['Authorization'] = 'Bearer invalid-fixture'
        self.assertEqual(self.client.get(self.base).status_code, 401)
        self.assertEqual(self.client.post(self.base + '/' + self.body['id'] + '/commit',
            json={'approval': review['approval']}).status_code, 401)
        self.backend.broadcast_transaction.assert_not_awaited()

    def test_short_fingerprint_collision_cannot_read_saved_payment(self):
        review = self.prepare()
        original = JamAdapter(self.state, self.token, self.state.wallet_name).identity
        other = WalletService(Mnemonic('english').to_mnemonic(bytes([1]) * 32),
            self.backend, network='regtest', data_dir=self.directory / 'other', scan_range=10)
        other.wallet_fingerprint = self.wallet.wallet_fingerprint
        self.state.wallet_service = other
        current = JamAdapter(self.state, self.token, self.state.wallet_name).identity
        self.assertNotEqual(current, original)
        self.assertEqual(self.client.get(self.base).json(), {'payments': []})
        self.assertEqual(self.client.post(self.base + '/' + self.body['id'] + '/commit',
            json={'approval': review['approval']}).status_code, 409)


if __name__ == '__main__':
    unittest.main()
