"""Real pinned Jam signer and HTTP routes, with an unfunded synthetic chain.

Run in the pinned dependency environment after applying install.py. No node,
production credentials or externally funded wallet is accessed by these tests.
"""
import asyncio
from datetime import datetime, timezone
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient
from loguru import logger
from mnemonic import Mnemonic
from jmcore.bitcoin import get_txid, parse_transaction
from jmcore.timenumber import timestamp_to_timenumber
from jmwallet.backends.base import Transaction
from jmwallet.wallet.address import pubkey_to_p2wpkh_script, script_to_p2wsh_scriptpubkey
from jmwallet.wallet.bond_registry import BondRegistry, create_bond_info, save_registry
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

    def test_coinjoin_capability_and_request_constraints(self):
        features = self.client.get('/api/v1/paperclip/capabilities').json()
        self.assertEqual(features['version'],2)
        self.assertTrue(features['coinjoin_payments'])
        # Invalid choices fail before the network-facing negotiation can start.
        with patch('paperclip_jam.adapter.coinjoin.prepare', AsyncMock()) as prepare:
            for extra in ({'rbf':True}, {'input_utxos':[self.coin.outpoint]}, {'amount_sat':0,'send_max':True}):
                body={**self.body,'coinjoin':True,'input_utxos':None,**extra}
                response=self.client.post(self.base,json=body)
                self.assertEqual(response.status_code,422)
            prepare.assert_not_awaited()
        self.backend.broadcast_transaction.assert_not_awaited()

    def tearDown(self):
        self.backend_patch.stop()
        self.client.close()
        self.app.state.paperclip_payments.journal.close()
        self.temp.cleanup()

    def prepare(self):
        response = self.client.post(self.base, json=self.body)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def test_market_comparison_is_read_only_and_available_during_review(self):
        self.prepare()
        result = {'amount_sat':100000, 'fetched_at':2000000000, 'book_updated_at':None,
                  'status':'unavailable', 'maker_count':0, 'median_fee_sat':None}
        with patch('paperclip_jam.api.snapshot', AsyncMock(return_value=result)) as market:
            self.assertEqual(self.client.get('/api/v1/paperclip/market/100000').json(), result)
            self.assertEqual(self.client.get('/api/v1/paperclip/market/1').status_code, 422)
            market.assert_awaited_once()
        self.backend.broadcast_transaction.assert_not_awaited()

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

    def test_first_run_creation_password_backup_and_existing_file_preservation(self):
        # Real encryption/file creation and password checks, synthetic chain only.
        # Never use response.text in assertions: lifecycle replies contain secrets.
        logger.remove()
        self.state.wallet_service = None
        self.state.wallet_name = None
        self.client.headers.pop('Authorization', None)
        wallet = 'new-fixture.jmdat'
        password = 'synthetic-test-password'
        with patch('jmwalletd._backend.get_backend', AsyncMock(return_value=self.backend)), \
                patch('jmwalletd.wallet_ops._get_network', return_value='regtest'), \
                patch.object(WalletService, 'sync', AsyncMock()), \
                patch.object(self.state, 'start_tx_monitor'), \
                patch.object(self.state, 'wait_tx_monitor_ready', AsyncMock(return_value=True)):
            created = self.client.post('/api/v1/wallet/create', json={
                'walletname': wallet, 'password': password, 'wallettype': 'sw-fb'})
            self.assertEqual(created.status_code, 201)
            self.assertTrue(Mnemonic('english').check(created.json()['seedphrase']))
            wallet_file = self.state.wallets_dir / wallet
            before = wallet_file.read_bytes()
            self.assertTrue(wallet_file.stat().st_mode & 0o777 == 0o600)
            seed_path = f'/api/v1/wallet/{wallet}/getseed'
            self.assertEqual(self.client.get(seed_path).status_code, 401)
            invalid = self.client.post(f'/api/v1/wallet/{wallet}/unlock', json={'password':'wrong-fixture'})
            self.assertNotEqual(invalid.status_code, 200)
            # The wrong-password backoff is tested upstream; skip its clock here.
            with patch.object(self.state, 'unlock_retry_delay', return_value=0):
                unlocked = self.client.post(f'/api/v1/wallet/{wallet}/unlock', json={'password':password})
            self.assertEqual(unlocked.status_code, 200)
            self.client.headers['Authorization'] = 'Bearer ' + unlocked.json()['token']
            backup = self.client.get(seed_path)
            self.assertEqual(backup.status_code, 200)
            self.assertTrue(backup.json()['seedphrase'] == created.json()['seedphrase'])
            self.state.wallet_service = None
            self.state.wallet_name = None
            duplicate = self.client.post('/api/v1/wallet/create', json={
                'walletname':wallet, 'password':password, 'wallettype':'sw-fb'})
            self.assertNotEqual(duplicate.status_code, 201)
            self.assertTrue(wallet_file.read_bytes() == before)
        self.backend.broadcast_transaction.assert_not_awaited()

    def test_owner_backup_remains_available_during_pending_payment(self):
        self.state.wallet_mnemonic = Mnemonic('english').to_mnemonic(bytes(32))
        self.prepare()
        target = '/api/v1/wallet/fixture.jmdat/getseed'
        response = self.client.get(target)
        self.assertEqual(response.status_code, 200)
        self.assertTrue(Mnemonic('english').check(response.json()['seedphrase']))
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
        from unittest.mock import patch, AsyncMock
        with patch('paperclip_jam.api.snapshot', AsyncMock(return_value={'status': 'unavailable'})) as market:
            self.assertEqual(self.client.get('/api/v1/paperclip/market/100000').status_code, 200)
            market.assert_awaited_once()
        for method, path in [('POST', target), ('POST', self.base),
                ('POST', self.base + '/' + 'a' * 64 + '/commit'),
                ('POST', self.base + '/' + 'a' * 64 + '/cancel'),
                ('GET', '/api/v1/wallet/fixture.jmdat/seed'),
                ('GET', '/api/v1/wallet/fixture.jmdat/getseed'),
                ('POST', '/api/v1/wallet/create'),
                ('POST', '/api/v1/wallet/fixture.jmdat/unlock'),
                ('GET', '/api/v1/wallet/all'), ('GET', '/api/v1/wallet/other.jmdat/utxos')]:
            self.assertEqual(self.client.request(method, path).status_code, 401, path)
        self.app.state.paperclip_delegations.record['expires'] = 1
        self.assertEqual(self.client.get(self.base).status_code, 401)
        self.backend.broadcast_transaction.assert_not_awaited()

    def test_payment_delegation_is_separate_and_never_exports_or_unlocks(self):
        target = self.base.replace('/payments', '/pairing-session')
        manage = self.client.post(target, json={}).json()['token']
        granted = self.client.post(target, json={'scope':'jars_pay_v1'})
        self.assertEqual(granted.status_code,200)
        pay = granted.json()['token']
        self.assertTrue(manage != pay)
        self.assertEqual(granted.json()['scope'],'jars_pay_v1')
        self.assertEqual(self.client.post(target,json={'scope':'all'}).status_code,422)
        for token in (manage,pay):
            self.client.headers['Authorization']='Bearer '+token
            for method,path in [('POST',target),('GET','/api/v1/wallet/fixture.jmdat/getseed'),
                    ('POST','/api/v1/wallet/fixture.jmdat/unlock'),('POST','/api/v1/wallet/create'),
                    ('POST','/api/v1/wallet/fixture.jmdat/taker/direct-send'),('POST','/api/v1/wallet/fixture.jmdat/taker/coinjoin'),
                    ('GET','/api/v1/wallet/other.jmdat/paperclip/payments')]:
                self.assertEqual(self.client.request(method,path).status_code,401,path)
        self.client.headers['Authorization']='Bearer '+manage
        self.assertEqual(self.client.post(self.base,json=self.body).status_code,401)
        self.client.headers['Authorization']='Bearer '+pay
        self.assertEqual(self.client.get('/api/v1/paperclip/capabilities').status_code,200)
        saved=self.prepare()
        self.backend.broadcast_transaction.assert_not_awaited()
        self.client.headers['Authorization']='Bearer '+manage
        self.assertEqual(self.client.post(self.base+'/'+'a'*64+'/commit',json={'approval':saved['approval']}).status_code,401)
        self.client.headers['Authorization']='Bearer '+pay
        self.backend.broadcast_transaction.side_effect=TimeoutError('Synthetic lost response')
        response=self.client.post(self.base+'/'+'a'*64+'/commit',json={'approval':saved['approval']})
        self.assertEqual(response.status_code,504)
        repeated=self.client.post(self.base+'/'+'a'*64+'/commit',json={'approval':saved['approval']})
        self.assertEqual(repeated.json()['state'],'unknown')
        self.backend.broadcast_transaction.assert_awaited_once()
        self.state._invalidate_ws_clients()
        self.assertEqual(self.client.get(self.base).status_code,401)

    def test_payment_delegation_can_cancel_only_an_unsent_review(self):
        target=self.base.replace('/payments','/pairing-session')
        pay=self.client.post(target,json={'scope':'jars_pay_v1'}).json()['token']
        self.client.headers['Authorization']='Bearer '+pay
        self.prepare()
        cancelled=self.client.post(self.base+'/'+'a'*64+'/cancel')
        self.assertEqual(cancelled.status_code,200)
        self.assertEqual(cancelled.json()['state'],'cancelled')
        self.app.state.paperclip_delegations.payment_record['expires']=1
        self.assertEqual(self.client.get(self.base).status_code,401)
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

    def registered_bond(self):
        locktime = int(datetime(2028, 1, 1, tzinfo=timezone.utc).timestamp())
        index = timestamp_to_timenumber(locktime)
        address = self.wallet.get_fidelity_bond_address(index, locktime)
        script = self.wallet.get_fidelity_bond_script(index, locktime)
        key = self.wallet.get_fidelity_bond_key(index, locktime)
        path = f"{self.wallet.root_path}/0'/2/{index}"
        bond = create_bond_info(address, locktime, index, path,
            key.get_public_key_bytes().hex(), script, self.wallet.network)
        registry = BondRegistry()
        registry.add_bond(bond)
        save_registry(registry, self.directory, self.wallet.wallet_fingerprint)
        return bond, script

    def bond_withdrawal(self):
        bond, script = self.registered_bond()
        self.coin = UTXOInfo(txid='3' * 64, vout=1, value=100_000,
            address=bond.address, confirmations=10,
            scriptpubkey=script_to_p2wsh_scriptpubkey(script).hex(),
            path=bond.path, mixdepth=0, locktime=bond.locktime)
        self.wallet.utxo_cache[0] = [self.coin]
        self.backend.get_utxo.return_value = self.coin
        self.body.update(purpose='withdraw_bond', bond_locktime=bond.locktime,
            amount_sat=0, send_max=True, max_total_sat=self.coin.value,
            input_utxos=[self.coin.outpoint])
        return bond, script

    def test_registered_bond_funding_signs_only_after_exact_date_review(self):
        bond, script = self.registered_bond()
        self.body.update(purpose='fund_bond', destination=bond.address,
            bond_locktime=bond.locktime)
        with patch('paperclip_jam.adapter.time.time', return_value=bond.locktime - 3600):
            review = self.prepare()
            self.assertEqual(review['quote']['bond_locktime'], bond.locktime)
            self.backend.broadcast_transaction.assert_not_awaited()
            result = self.client.post(self.base + '/' + self.body['id'] + '/commit',
                json={'approval': review['approval']})
        self.assertEqual(result.status_code, 200)
        self.backend.broadcast_transaction.assert_awaited_once()
        transaction = parse_transaction(self.backend.broadcast_transaction.await_args.args[0])
        outputs = [output for output in transaction.outputs
            if output.script == script_to_p2wsh_scriptpubkey(script)]
        self.assertEqual(len(outputs), 1)
        self.assertEqual(outputs[0].value, self.body['amount_sat'])

    def test_delegated_bond_funding_preserves_date_and_never_repeats_submission(self):
        bond, _ = self.registered_bond()
        delegated = self.client.post(self.base.replace('/payments', '/pairing-session'),
            json={'scope':'jars_pay_v1'})
        self.assertEqual(delegated.status_code,200)
        self.client.headers['Authorization']='Bearer '+delegated.json()['token']
        self.body.update(purpose='fund_bond',destination=bond.address,bond_locktime=bond.locktime)
        with patch('paperclip_jam.adapter.time',SimpleNamespace(time=lambda:bond.locktime-3600)):
            review=self.prepare()
            self.assertEqual(review['quote']['bond_locktime'],bond.locktime)
            self.backend.broadcast_transaction.assert_not_awaited()
            self.backend.broadcast_transaction.side_effect=TimeoutError('Synthetic lost bond submission')
            target=self.base+'/'+self.body['id']+'/commit'
            self.assertEqual(self.client.post(target,json={'approval':review['approval']}).status_code,504)
            self.assertEqual(self.client.post(target,json={'approval':review['approval']}).json()['state'],'unknown')
            self.backend.broadcast_transaction.assert_awaited_once()

    def test_bond_funding_rejects_wrong_date_and_ordinary_send_bypass(self):
        bond, _ = self.registered_bond()
        self.body.update(destination=bond.address)
        for number, changes in enumerate([
                {}, {'purpose':'fund_bond', 'bond_locktime':bond.locktime + 86400},
                {'purpose':'fund_bond', 'bond_locktime':bond.locktime,
                 'destination':self.wallet.get_receive_address(1, 0)}]):
            with self.subTest(changes=number):
                body = {**self.body, **changes, 'id': f'{number + 1:064x}'}
                self.assertEqual(self.client.post(self.base, json=body).status_code, 409)
        self.backend.broadcast_transaction.assert_not_awaited()

    def test_bond_funding_cannot_commit_after_unlock_date(self):
        bond, _ = self.registered_bond()
        self.body.update(purpose='fund_bond', destination=bond.address,
            bond_locktime=bond.locktime)
        with patch('paperclip_jam.adapter.time.time', return_value=bond.locktime - 3600):
            review = self.prepare()
        with patch('paperclip_jam.adapter.time.time', return_value=bond.locktime):
            result = self.client.post(self.base + '/' + self.body['id'] + '/commit',
                json={'approval': review['approval']})
        self.assertEqual(result.status_code, 409)
        self.backend.broadcast_transaction.assert_not_awaited()

    def test_bond_withdrawal_requires_chain_maturity_and_real_cltv_witness(self):
        bond, script = self.bond_withdrawal()
        self.backend.get_median_time_past.return_value = bond.locktime
        self.assertEqual(self.client.post(self.base, json=self.body).status_code, 409)
        self.backend.broadcast_transaction.assert_not_awaited()
        # Failed preparation is terminal; explicitly create a different review.
        self.body['id'] = 'b' * 64
        self.backend.get_median_time_past.return_value = bond.locktime + 1
        review = self.prepare()
        self.assertEqual(review['quote']['amount_sat'] + review['quote']['fee_sat'], self.coin.value)
        self.assertEqual(review['quote']['change_sat'], 0)
        result = self.client.post(self.base + '/' + self.body['id'] + '/commit',
            json={'approval': review['approval']})
        self.assertEqual(result.status_code, 200)
        self.backend.broadcast_transaction.assert_awaited_once()
        transaction = parse_transaction(self.backend.broadcast_transaction.await_args.args[0])
        self.assertEqual(transaction.locktime, bond.locktime)
        self.assertEqual(len(transaction.inputs), 1)
        self.assertLess(transaction.inputs[0].sequence, 0xffffffff)
        self.assertEqual(transaction.witnesses[0][-1], script)

    def test_bond_withdrawal_rechecks_chain_time_and_freeze_after_review(self):
        bond, _ = self.bond_withdrawal()
        self.backend.get_median_time_past.return_value = bond.locktime + 1
        review = self.prepare()
        target = self.base + '/' + self.body['id'] + '/commit'
        self.backend.get_median_time_past.return_value = bond.locktime
        self.assertEqual(self.client.post(target, json={'approval':review['approval']}).status_code, 409)
        self.backend.get_median_time_past.return_value = bond.locktime + 1
        self.coin.frozen = True
        self.assertEqual(self.client.post(target, json={'approval':review['approval']}).status_code, 409)
        self.backend.broadcast_transaction.assert_not_awaited()

    def test_ordinary_send_never_spends_matured_bond_even_automatically(self):
        bond, _ = self.bond_withdrawal()
        self.backend.get_median_time_past.return_value = bond.locktime + 1
        self.body.update(purpose='send', bond_locktime=None)
        self.assertEqual(self.client.post(self.base, json=self.body).status_code, 409)
        self.body.update(id='b' * 64, input_utxos=None)
        self.assertEqual(self.client.post(self.base, json=self.body).status_code, 409)
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
