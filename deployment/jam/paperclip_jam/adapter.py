"""Pinned JoinBlaket integration. Only commit may call broadcast_transaction."""
import hashlib
import time

from jmcore.bitcoin import get_txid
from jmcore.settings import get_settings
from jmcore.timenumber import timestamp_to_timenumber
from jmwallet.history import append_history_entry, create_send_history_entry, update_send_awaiting_broadcast, update_taker_awaiting_transaction_broadcast
from jmwallet.wallet.bond_registry import load_registry
from jmwallet.wallet.spend import prepare_direct_send, resolve_input_utxos
from jmwalletd._backend import get_backend
from jmwalletd.deps import require_wallet_session

from .journal import PaymentConflict
from . import coinjoin


class JamAdapter:
    def __init__(self, state, token, walletname):
        self.state, self.token, self.walletname = state, token, walletname
        self.wallet, self.generation = require_wallet_session(state, token, walletname)
        fingerprint = self.wallet.wallet_fingerprint
        if not fingerprint or self.wallet.network not in ('mainnet', 'testnet', 'signet', 'regtest'):
            raise PaymentConflict('Jam wallet identity is unavailable')
        # BIP32's four-byte fingerprint is for display, not payment ownership.
        root = self.wallet.master_key
        commitment = hashlib.sha256(b'paperclip-jam-wallet-v1\0' +
            self.wallet.network.encode() + b'\0' + bytes(root.public_key) + root.chain_code).hexdigest()
        self.identity = 'xbt-' + self.wallet.network + ':' + commitment
        self.backend = None

    def authorize(self):
        wallet, generation = require_wallet_session(self.state, self.token, self.walletname)
        if wallet is not self.wallet or generation != self.generation:
            raise PaymentConflict('Jam wallet session changed; review again')

    def idle(self):
        self.authorize()
        if self.state.maker_running or self.state.taker_running or self.state.rescanning or self.state.tumble_runner is not None:
            raise PaymentConflict('Stop the maker and wait for Jam to become idle before sending')

    async def connect(self):
        self.authorize()
        self.backend = await get_backend(self.wallet.data_dir, wallet_service=self.wallet)
        self.authorize()
        return self.backend

    async def prepare(self, request):
        self.idle()
        if request.get('coinjoin'):
            return await coinjoin.prepare(self, request)
        backend = await self.connect()
        await self.wallet.sync_with_registered_bonds()
        self.idle()
        coins = await self.wallet.get_utxos(request['jar'])
        self.authorize()
        by_outpoint = {f'{coin.txid}:{coin.vout}': coin for coin in coins}
        purpose = request['purpose']
        registry = load_registry(self.wallet.data_dir, self.wallet.wallet_fingerprint, allow_legacy_fallback=False)
        bond = registry.get_bond_by_address(request['destination'].lower())
        if purpose == 'fund_bond':
            if bond is None or bond.locktime != request['bond_locktime'] or bond.locktime <= time.time():
                raise PaymentConflict('Destination and unlock date must match this wallet’s registered bond')
            if self.wallet.get_fidelity_bond_address(timestamp_to_timenumber(bond.locktime), bond.locktime) != bond.address:
                raise PaymentConflict('Bond destination does not belong to this Jam wallet')
        elif bond is not None:
            raise PaymentConflict('Use the bond funding review for a registered bond destination')
        selected = request['input_utxos']
        if purpose == 'withdraw_bond':
            if not selected or len(selected) != 1 or not request['send_max']:
                raise PaymentConflict('Choose one matured bond and review its full withdrawal')
            coin = by_outpoint.get(selected[0])
            if coin is None or coin.locktime is None or coin.locktime != request['bond_locktime']:
                raise PaymentConflict('Selected bond or unlock date changed')
        elif selected and any(by_outpoint.get(point) is None or by_outpoint[point].locktime is not None for point in selected):
            raise PaymentConflict('Ordinary jar sends cannot include bond coins')
        prepared = await prepare_direct_send(wallet=self.wallet, backend=backend,
            mixdepth=request['jar'], amount_sats=0 if request['send_max'] else request['amount_sat'],
            destination=request['destination'], fee_rate=request['fee_rate_millisat_vb'] / 1000,
            max_fee_rate_sat_vb=get_settings().wallet.max_fee_rate_sat_vb,
            tx_fee_factor=0.0, input_utxos=selected, rbf=request['rbf'], authorization_check=self.authorize)
        self.idle()
        used = [by_outpoint.get(f'{txid}:{vout}') for txid, vout in prepared.selected_utxos]
        if not used or any(coin is None for coin in used):
            raise PaymentConflict('Prepared inputs do not match this jar')
        if purpose != 'withdraw_bond' and any(coin.locktime is not None for coin in used):
            raise PaymentConflict('Bond coins require a separate withdrawal review')
        total = prepared.send_amount + prepared.fee
        if prepared.fee < 0 or prepared.fee > request['max_fee_sat'] or total > request['max_total_sat']:
            raise PaymentConflict('Prepared payment exceeds the approved cost limits')
        if not request['send_max'] and prepared.send_amount != request['amount_sat']:
            raise PaymentConflict('Prepared recipient amount changed')
        quote = {'wallet': self.walletname, 'wallet_identity': self.identity, 'jar': request['jar'],
            'network': 'xbt-' + self.wallet.network, 'purpose': purpose,
            'destination': prepared.destination, 'amount_sat': prepared.send_amount,
            'fee_sat': prepared.fee, 'total_sat': total, 'change_sat': prepared.change_amount,
            'txid': prepared.txid, 'rbf': request['rbf'], 'bond_locktime': request['bond_locktime'],
            'change_address': prepared.change_address, 'source_addresses': prepared.source_addresses,
            'inputs': [{'outpoint': f'{coin.txid}:{coin.vout}', 'amount_sat': coin.value,
                        'scriptpubkey': coin.scriptpubkey, 'locktime': coin.locktime} for coin in used]}
        if sum(coin.value for coin in used) != total + prepared.change_amount or get_txid(prepared.tx_hex) != prepared.txid:
            raise PaymentConflict('Prepared payment does not conserve the selected value')
        # Persist address use without inventing a failed/successful payment.
        self.wallet.metadata_store.mark_addresses_used(
            [address for address in (prepared.destination, prepared.change_address) if address],
            origin='paperclip-review')
        return quote, prepared.tx_hex

    async def validate_inputs(self, quote):
        self.idle()
        if quote['purpose'] == 'fund_bond' and quote['bond_locktime'] <= time.time():
            raise PaymentConflict('Bond unlock date passed; create a new review')
        backend = await self.connect()
        await self.wallet.sync_with_registered_bonds()
        self.idle()
        # Upstream verifies wallet ownership, jar, freeze state and chain MTP for bonds.
        if quote.get('coinjoin'):
            await coinjoin.validate_inputs(self, quote)
            return
        coins, _ = await resolve_input_utxos(wallet=self.wallet, backend=backend,
            mixdepth=quote['jar'], input_utxos=[item['outpoint'] for item in quote['inputs']],
            allow_fidelity_bonds=quote['purpose'] == 'withdraw_bond')
        self.idle()
        current = {f'{coin.txid}:{coin.vout}': coin for coin in coins}
        for item in quote['inputs']:
            coin = current.get(item['outpoint'])
            if coin is None or coin.value != item['amount_sat'] or coin.scriptpubkey != item['scriptpubkey'] or coin.locktime != item['locktime']:
                raise PaymentConflict('Selected coins changed; create a new payment review')
            chain_coin = await backend.get_utxo(coin.txid, coin.vout)
            self.idle()
            if chain_coin is None or chain_coin.value != coin.value or chain_coin.scriptpubkey != coin.scriptpubkey:
                raise PaymentConflict('The node no longer reports the reviewed unspent coins')

    async def broadcast(self, signed, quote):
        self.authorize()
        if quote.get('coinjoin'):
            # The durable claim is already committed. Upstream negotiation has
            # stopped and this is the only permitted network submission.
            txid = await self.backend.broadcast_transaction(signed)
            if txid == quote['txid']:
                update_taker_awaiting_transaction_broadcast(destination_address=quote['destination'],
                    change_address=quote['change_address'], txid=txid,
                    mining_fee=quote['mining_fee_sat'], broadcast_method='self', broadcast_policy='self',
                    data_dir=self.wallet.data_dir, wallet_fingerprint=self.wallet.wallet_fingerprint)
            return txid
        entry = create_send_history_entry(destination=quote['destination'],
            change_address=quote['change_address'], amount=quote['amount_sat'],
            mining_fee=quote['fee_sat'], source_mixdepth=quote['jar'],
            selected_utxos=[(item['outpoint'].split(':')[0], int(item['outpoint'].split(':')[1])) for item in quote['inputs']],
            success=False, failure_reason='awaiting broadcast', network=self.wallet.network,
            wallet_fingerprint=self.wallet.wallet_fingerprint, source_addresses=quote['source_addresses'])
        append_history_entry(entry, data_dir=self.wallet.data_dir)
        # No await between the final authorization, journal/history persistence
        # and initiating the one permitted broadcast.
        try:
            txid = await self.backend.broadcast_transaction(signed)
        except BaseException:
            update_send_awaiting_broadcast(entry, txid=quote['txid'], success=False,
                failure_reason='Submission unresolved; check Paperclip payment status', data_dir=self.wallet.data_dir)
            raise
        update_send_awaiting_broadcast(entry, txid=quote['txid'], success=txid == quote['txid'],
            failure_reason='' if txid == quote['txid'] else 'Submission unresolved; check Paperclip payment status',
            data_dir=self.wallet.data_dir)
        return txid

    async def observe(self, quote):
        backend = await self.connect()
        transaction = await backend.get_transaction(quote['txid'])
        self.authorize()
        if transaction is None or transaction.confirmations < 0:
            return False
        return transaction.txid == quote['txid'] and get_txid(transaction.raw) == quote['txid']
