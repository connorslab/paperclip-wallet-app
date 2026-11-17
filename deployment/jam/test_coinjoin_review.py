"""Unfunded three-wallet signed CoinJoin fixtures; all network calls are mocked."""
import asyncio
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, patch

from loguru import logger
from mnemonic import Mnemonic
from jmcore.bitcoin import TxInput, TxOutput, address_to_scriptpubkey_for_network, serialize_transaction
from jmcore.models import Offer
from taker.taker import Taker
from paperclip_jam.adapter import JamAdapter
from jmwallet.wallet.models import UTXOInfo
from jmwallet.wallet.service import WalletService
from jmwallet.wallet.signing import deserialize_transaction

from paperclip_jam import coinjoin
from paperclip_jam.journal import Journal, PaymentConflict
from paperclip_jam.payments import Payments


class CoinjoinReviewTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        logger.remove()
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.backend = AsyncMock()
        self.wallets = []
        self.coins = []
        for index in range(3):
            wallet = WalletService(Mnemonic('english').to_mnemonic(bytes([index]) * 32), self.backend,
                network='regtest', data_dir=self.root / str(index), scan_range=10)
            address = wallet.get_receive_address(0, 0)
            coin = UTXOInfo(txid=str(index + 1) * 64, vout=0, value=100000 if index == 0 else 50000,
                address=address, confirmations=10, scriptpubkey=address_to_scriptpubkey_for_network(address, 'regtest').hex(),
                path="m/84'/1'/0'/0/0", mixdepth=0)
            wallet.utxo_cache = {jar: [coin] if jar == 0 else [] for jar in range(5)}
            self.wallets.append(wallet); self.coins.append(coin)
        wallet = self.wallets[0]
        self.destination = self.wallets[1].get_receive_address(0, 3)
        self.change = wallet.get_receive_address(0, 2)
        destinations = [(self.destination, 30000), (self.change, 69000),
            (self.wallets[1].get_receive_address(0, 1), 30000), (self.wallets[1].get_receive_address(0, 2), 20200),
            (self.wallets[2].get_receive_address(0, 1), 30000), (self.wallets[2].get_receive_address(0, 2), 20200)]
        self.inputs = [TxInput.from_hex(c.txid, c.vout, sequence=0xfffffffe) for c in self.coins]
        self.outputs = [TxOutput(value=value, script=address_to_scriptpubkey_for_network(address, 'regtest')) for address, value in destinations]
        unsigned = serialize_transaction(2, self.inputs, self.outputs, 200)
        parsed = deserialize_transaction(unsigned)
        spent = [(c.value, bytes.fromhex(c.scriptpubkey)) for c in self.coins]
        self.witnesses = [w.sign_input(parsed, i, c, spent).witness for i, (w, c) in enumerate(zip(self.wallets, self.coins))]
        self.owner = 'f' * 64
        self.assertTrue(wallet.reserve_coinjoin_inputs({(self.coins[0].txid, 0)}, owner=self.owner))
        self.round = SimpleNamespace(final_tx=serialize_transaction(2, self.inputs, self.outputs, 200, self.witnesses),
            taker_change_address=self.change, selected_utxos=[self.coins[0]], input_lock_owner=self.owner,
            maker_sessions={'maker1':object(),'maker2':object()}, maker_fee_plan=lambda: {'maker1':200,'maker2':200})
        self.taker = SimpleNamespace(_session=self.round)
        self.backend.get_utxo.side_effect = lambda txid, vout: next((c for c in self.coins if c.txid == txid and c.vout == vout), None)
        self.active = True
        def authorize():
            if not self.active: raise PaymentConflict('Wallet session ended')
        self.adapter = SimpleNamespace(wallet=wallet, walletname='fixture.jmdat', backend=self.backend,
            identity='xbt-regtest:'+'c'*64, authorize=authorize, idle=authorize, generation=1)
        self.request = {'purpose':'send','coinjoin':True,'jar':0,'destination':self.destination,'amount_sat':30000,
            'max_fee_sat':1000,'max_total_sat':31000,'fee_rate_millisat_vb':1000,'send_max':False,'rbf':False,
            'input_utxos':None,'bond_locktime':None}
        self.details = {'destination':self.destination,'cj_amount':30000,'total_fee':1000,'stage':'broadcast'}

    async def asyncTearDown(self):
        self.temp.cleanup()

    async def review(self):
        return await coinjoin.final_review(self.adapter, self.request, self.taker, self.details)

    async def test_signed_review_has_exact_debit_and_never_broadcasts(self):
        quote, signed = await self.review()
        self.assertTrue(quote['coinjoin']); self.assertFalse(quote['rbf'])
        self.assertEqual((quote['maker_fee_sat'], quote['mining_fee_sat'], quote['fee_sat'], quote['total_sat']), (400,600,1000,31000))
        self.assertEqual(quote['maker_count'],2); self.assertEqual(len(quote['chain_inputs']),3)
        self.assertEqual(signed,self.round.final_tx.hex())
        self.backend.broadcast_transaction.assert_not_awaited()

    async def test_fee_limit_and_missing_signatures_fail_closed(self):
        self.request['max_fee_sat'] = 999
        with self.assertRaises(PaymentConflict): await self.review()
        self.request['max_fee_sat'] = 1000
        self.round.final_tx = serialize_transaction(2,self.inputs,self.outputs,200)
        with self.assertRaises(PaymentConflict): await self.review()
        self.backend.broadcast_transaction.assert_not_awaited()

    async def test_recipient_amount_equal_outputs_and_jar_cannot_change(self):
        for key, value in [('destination',self.change),('amount_sat',30001),('jar',1)]:
            old=self.request[key]; self.request[key]=value
            with self.assertRaises(PaymentConflict): await self.review()
            self.request[key]=old
        original=self.round.maker_sessions
        self.round.maker_sessions={'only-one':object()}
        with self.assertRaises(PaymentConflict): await self.review()
        self.round.maker_sessions=original

    async def test_commit_rechecks_maker_inputs_and_exact_lock_owner(self):
        quote,_=await self.review()
        await coinjoin.validate_inputs(self.adapter,quote)
        self.backend.get_utxo.side_effect=lambda txid,vout: self.coins[0] if txid==self.coins[0].txid else None
        with self.assertRaises(PaymentConflict): await coinjoin.validate_inputs(self.adapter,quote)
        quote['input_lock_owner']='e'*64
        with self.assertRaises(PaymentConflict): await coinjoin.validate_inputs(self.adapter,quote)
        self.assertIn((self.coins[0].txid,0),self.wallets[0].get_locked_input_outpoints())
        self.backend.broadcast_transaction.assert_not_awaited()

    async def test_freeze_or_session_change_prevents_review_and_commit(self):
        quote,_=await self.review()
        self.wallets[0].toggle_freeze_utxo(self.coins[0].outpoint)
        with self.assertRaises(PaymentConflict): await coinjoin.validate_inputs(self.adapter,quote)
        with self.assertRaises(PaymentConflict): await self.review()
        self.active=False
        with self.assertRaises(PaymentConflict): await coinjoin.validate_inputs(self.adapter,quote)

    async def test_preparation_declines_automatic_broadcast_and_restores_state(self):
        state=SimpleNamespace(wallet_mnemonic='unfunded fixture only',wallet_bip39_passphrase='',wallet_generation=1,
            activate_coinjoin_state=Mock(),_taker_ref=None,_taker_task=None)
        self.adapter.state=state
        current=self.round; details=self.details; calls=[]
        class FixtureTaker:
            def __init__(self, **kwargs): self.callback=kwargs['confirmation_callback']; self._session=current
            async def start(self): pass
            async def stop(self, **kwargs): calls.append('stopped')
            async def do_coinjoin(self, **kwargs):
                accepted=await self.callback(**{**details,'stage':'initial'})
                calls.append(('initial',accepted))
                if accepted:
                    broadcast=await self.callback(**details);calls.append(('broadcast',broadcast))
                    if broadcast: raise AssertionError('Automatic broadcast must be refused')
        with patch.object(coinjoin,'Taker',FixtureTaker), patch.object(coinjoin,'TakerConfig',lambda **kw:object()), \
             patch.object(coinjoin,'build_taker_config_kwargs',return_value={}), patch.object(coinjoin,'get_backend',AsyncMock(return_value=self.backend)):
            quote,_=await coinjoin.prepare(self.adapter,self.request)
        self.assertTrue(quote['coinjoin']);self.assertEqual(calls,[('initial',True),('broadcast',False),'stopped'])
        self.assertIsNone(state._taker_task);self.assertIsNone(state._taker_ref)
        self.backend.broadcast_transaction.assert_not_awaited();self.backend.close.assert_awaited_once()
        self.backend.close.side_effect = OSError('Synthetic backend cleanup failure')
        with patch.object(coinjoin,'Taker',FixtureTaker), patch.object(coinjoin,'TakerConfig',lambda **kw:object()), \
             patch.object(coinjoin,'build_taker_config_kwargs',return_value={}), patch.object(coinjoin,'get_backend',AsyncMock(return_value=self.backend)):
            with self.assertRaises(OSError): await coinjoin.prepare(self.adapter,self.request)
        self.assertIsNone(state._taker_task);self.assertIsNone(state._taker_ref)
        self.backend.broadcast_transaction.assert_not_awaited()

    async def test_pinned_final_confirmation_cannot_broadcast(self):
        # Exercise the real pinned method, not a replacement Taker implementation.
        current = self.round
        current._minimum_fee_rate_sat_vb = 1
        current.cj_amount = 30000
        current._log_manual_csv_entry = Mock()
        current._phase_broadcast = AsyncMock(side_effect=AssertionError('Automatic broadcast'))
        current.maker_sessions = {
            'maker'+str(i): SimpleNamespace(utxos=[{'value': coin.value}],
                offer=Offer(counterparty='maker'+str(i),oid=0,ordertype='sw0absoffer',
                    minsize=27300,maxsize=100000,txfee=0,cjfee=200))
            for i,coin in enumerate(self.coins[1:],1)}
        taker = Taker.__new__(Taker)
        taker._session = current
        taker.config = SimpleNamespace(max_fee_rate_sat_vb=10000)
        taker.directory_client = SimpleNamespace(clients={})
        captured = []
        async def decline(**details):
            captured.append(await coinjoin.final_review(self.adapter,self.request,taker,details))
            return False
        taker.confirmation_callback = decline
        self.assertIsNone(await taker._finalize_and_broadcast(self.destination))
        self.assertEqual(len(captured),1)
        current._phase_broadcast.assert_not_awaited()
        self.backend.broadcast_transaction.assert_not_awaited()

    async def test_reviewed_coinjoin_commits_once_and_survives_lost_response(self):
        journal = Journal(self.root / 'journal')
        try:
            service = Payments(journal)
            async def prepare(request): return await self.review()
            async def validate(quote): await coinjoin.validate_inputs(self.adapter,quote)
            async def broadcast(signed,quote): return await JamAdapter.broadcast(self.adapter,signed,quote)
            self.adapter.prepare = prepare; self.adapter.validate_inputs = validate; self.adapter.broadcast = broadcast
            saved = await service.prepare(self.adapter,'a'*64,self.request)
            self.backend.broadcast_transaction.assert_not_awaited()
            self.backend.broadcast_transaction.side_effect = TimeoutError('Synthetic lost broadcast')
            with self.assertRaises(TimeoutError): await service.commit(self.adapter,'a'*64,saved['approval'])
            self.assertEqual(journal.status(self.adapter.identity,'a'*64)['state'],'unknown')
            journal.close(); journal = Journal(self.root / 'journal'); service = Payments(journal)
            observed = await service.commit(self.adapter,'a'*64,saved['approval'])
            self.assertEqual(observed['state'],'unknown')
            self.backend.broadcast_transaction.assert_awaited_once()
        finally: journal.close()

    async def test_cancelled_preparation_cannot_leave_an_actionable_review(self):
        journal = Journal(self.root / 'cancel')
        try:
            async def prepare(request):
                await self.review()
                raise asyncio.CancelledError()
            self.adapter.prepare=prepare
            with self.assertRaises(asyncio.CancelledError):
                await Payments(journal).prepare(self.adapter,'a'*64,self.request)
            self.assertEqual(journal.status(self.adapter.identity,'a'*64)['state'],'cancelled')
            self.assertFalse(journal.pending())
            self.backend.broadcast_transaction.assert_not_awaited()
        finally: journal.close()

    async def test_constructor_failure_closes_backend_without_changing_state(self):
        self.adapter.state=SimpleNamespace(wallet_mnemonic='unfunded fixture only',wallet_bip39_passphrase='',wallet_generation=1,
            activate_coinjoin_state=Mock(),_taker_ref=None,_taker_task=None)
        with patch.object(coinjoin,'Taker',side_effect=ValueError('Synthetic invalid config')), \
             patch.object(coinjoin,'TakerConfig',lambda **kw:object()), \
             patch.object(coinjoin,'build_taker_config_kwargs',return_value={}), \
             patch.object(coinjoin,'get_backend',AsyncMock(return_value=self.backend)):
            with self.assertRaises(ValueError): await coinjoin.prepare(self.adapter,self.request)
        self.backend.close.assert_awaited_once()
        self.adapter.state.activate_coinjoin_state.assert_not_called()

    async def test_explicit_commit_records_submission_without_rebroadcast(self):
        journal = Journal(self.root / 'success')
        try:
            quote,signed = await self.review()
            self.adapter.prepare=AsyncMock(return_value=(quote,signed))
            async def validate(value): await coinjoin.validate_inputs(self.adapter,value)
            async def broadcast(raw,value): return await JamAdapter.broadcast(self.adapter,raw,value)
            self.adapter.validate_inputs=validate; self.adapter.broadcast=broadcast
            self.backend.broadcast_transaction.return_value=quote['txid']
            service=Payments(journal)
            saved=await service.prepare(self.adapter,'a'*64,self.request)
            with patch('paperclip_jam.adapter.update_taker_awaiting_transaction_broadcast') as history:
                result=await service.commit(self.adapter,'a'*64,saved['approval'])
                self.assertEqual(result['state'],'submitted')
                repeated=await service.commit(self.adapter,'a'*64,saved['approval'])
                self.assertEqual(repeated['state'],'submitted')
                history.assert_called_once()
                self.assertEqual(history.call_args.kwargs['broadcast_policy'],'self')
                self.assertEqual(history.call_args.kwargs['txid'],quote['txid'])
            self.backend.broadcast_transaction.assert_awaited_once_with(signed)
        finally: journal.close()
