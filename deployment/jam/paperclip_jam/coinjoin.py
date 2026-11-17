"""Negotiate a pinned Jam CoinJoin, but leave broadcasting to Payments.commit.

The final confirmation hook always declines upstream broadcast. Signed bytes stay
in the private payment journal. A prepared CoinJoin is broadcast through the owner's
Jam node only after review; no peer-broadcast or direct-send fallback is attempted.
"""
import asyncio
import re

from jmcore.bitcoin import address_to_scriptpubkey_for_network, get_txid, parse_transaction
from jmcore.settings import get_settings
from jmwallet.wallet.bond_registry import load_registry
from jmwalletd._backend import get_backend
from jmwalletd.state import CoinjoinState
from taker.config import TakerConfig
from taker.config_builder import build_taker_config_kwargs
from taker.taker import Taker

from .journal import PaymentConflict


def bounded_int(value, minimum=0, maximum=2_100_000_000_000_000):
    if type(value) is not int or not minimum <= value <= maximum:
        raise PaymentConflict('Invalid CoinJoin amount')
    return value


async def final_review(adapter, request, taker, details):
    """Bind actual signed outputs and current prevouts, not only callback totals."""
    adapter.authorize()
    if details.get('destination') != request['destination'] or details.get('cj_amount') != request['amount_sat']:
        raise PaymentConflict('CoinJoin recipient or amount changed')
    current = taker._session  # Pinned runtime; the build verifies this source contract.
    raw = current.final_tx.hex()
    if len(raw) > 400_000:
        raise PaymentConflict('CoinJoin transaction exceeds review limits')
    tx = parse_transaction(raw)
    if not tx.has_witness or len(tx.witnesses) != len(tx.inputs) or any(not witness for witness in tx.witnesses):
        raise PaymentConflict('CoinJoin transaction is not fully signed')
    if not 3 <= len(tx.inputs) <= 200 or not 3 <= len(tx.outputs) <= 400 or any(item.sequence < 0xfffffffe for item in tx.inputs):
        raise PaymentConflict('Unsupported CoinJoin transaction shape')
    maker_count = len(current.maker_sessions)
    if not 2 <= maker_count <= 20 or len([o for o in tx.outputs if o.value == request['amount_sat']]) < maker_count + 1:
        raise PaymentConflict('CoinJoin equal outputs or maker count changed')
    destination_script = address_to_scriptpubkey_for_network(request['destination'], adapter.wallet.network)
    recipients = [o for o in tx.outputs if o.script == destination_script]
    if len(recipients) != 1 or recipients[0].value != request['amount_sat']:
        raise PaymentConflict('CoinJoin recipient output changed')
    change_address = current.taker_change_address or ''
    change = 0
    if change_address:
        if not adapter.wallet.get_key_for_address(change_address):
            raise PaymentConflict('CoinJoin change is not owned by this wallet')
        script = address_to_scriptpubkey_for_network(change_address, adapter.wallet.network)
        changes = [o for o in tx.outputs if o.script == script]
        if script == destination_script or len(changes) != 1:
            raise PaymentConflict('CoinJoin change output changed')
        change = bounded_int(changes[0].value)
    coins = await adapter.wallet.get_utxos(request['jar'])
    adapter.authorize()
    own = {coin.outpoint: coin for coin in coins if coin.locktime is None and not coin.frozen}
    selected = {coin.outpoint for coin in current.selected_utxos}
    actual = {f'{i.txid}:{i.vout}' for i in tx.inputs}
    if len(actual) != len(tx.inputs) or not selected or not selected <= actual or not selected <= own.keys():
        raise PaymentConflict('CoinJoin inputs changed or belong to another jar')
    owner = current.input_lock_owner
    points = {(own[point].txid, own[point].vout) for point in selected}
    if not re.fullmatch('[0-9a-f]{64}', owner) or not adapter.wallet.renew_coinjoin_inputs(points, owner=owner):
        raise PaymentConflict('CoinJoin input reservation changed')
    # Any additional wallet input is an unreviewed debit, including other jars.
    for jar in range(5):
        wallet_coins = await adapter.wallet.get_utxos(jar)
        adapter.authorize()
        if ({coin.outpoint for coin in wallet_coins} & actual) - selected:
            raise PaymentConflict('CoinJoin includes an unselected wallet input')
    chain_inputs = []
    for item in tx.inputs:
        coin = await adapter.backend.get_utxo(item.txid, item.vout)
        adapter.authorize()
        if coin is None:
            raise PaymentConflict('CoinJoin input is no longer unspent')
        value = bounded_int(coin.value, 1)
        point = f'{item.txid}:{item.vout}'
        if point in selected and (value != own[point].value or coin.scriptpubkey != own[point].scriptpubkey):
            raise PaymentConflict('CoinJoin wallet input changed')
        chain_inputs.append({'outpoint': point, 'amount_sat': value, 'scriptpubkey': coin.scriptpubkey})
    output_total = sum(bounded_int(o.value) for o in tx.outputs)
    network_fee = sum(i['amount_sat'] for i in chain_inputs) - output_total
    bounded_int(network_fee)
    fee = sum(own[point].value for point in selected) - change - request['amount_sat']
    bounded_int(fee)
    maker_fee = sum(bounded_int(value) for value in current.maker_fee_plan().values())
    mining_share = fee - maker_fee
    bounded_int(mining_share)
    if mining_share > network_fee:
        raise PaymentConflict('CoinJoin mining fee share exceeds the transaction fee')
    if fee > request['max_fee_sat'] or request['amount_sat'] + fee > request['max_total_sat']:
        raise PaymentConflict('CoinJoin exceeds the approved total cost limit')
    used = [own[point] for point in sorted(selected)]
    quote = {'wallet': adapter.walletname, 'wallet_identity': adapter.identity,
        'network': 'xbt-' + adapter.wallet.network, 'purpose': 'send', 'coinjoin': True,
        'jar': request['jar'], 'destination': request['destination'], 'amount_sat': request['amount_sat'],
        'fee_sat': fee, 'total_sat': request['amount_sat'] + fee, 'change_sat': change,
        'maker_fee_sat': maker_fee, 'mining_fee_sat': mining_share, 'network_fee_sat': network_fee,
        'maker_count': maker_count, 'broadcast_policy': 'self', 'rbf': False, 'bond_locktime': None,
        'txid': get_txid(raw), 'change_address': change_address,
        'source_addresses': [coin.address for coin in used], 'chain_inputs': chain_inputs,
        'input_lock_owner': owner,
        'inputs': [{'outpoint': coin.outpoint, 'amount_sat': coin.value, 'scriptpubkey': coin.scriptpubkey,
                    'locktime': None} for coin in used]}
    return quote, raw


async def validate_inputs(adapter, quote):
    """Renew only this exact signed round's leases; never release another owner."""
    own = {coin.outpoint: coin for coin in await adapter.wallet.get_utxos(quote['jar'])}
    adapter.idle()
    points = set()
    for item in quote['inputs']:
        coin = own.get(item['outpoint'])
        if coin is None or coin.frozen or adapter.wallet.is_utxo_frozen(item['outpoint']) or coin.locktime is not None or coin.value != item['amount_sat'] or coin.scriptpubkey != item['scriptpubkey']:
            raise PaymentConflict('Reviewed CoinJoin wallet inputs changed')
        points.add((coin.txid, coin.vout))
    owner = quote['input_lock_owner']
    if not points or not re.fullmatch('[0-9a-f]{64}', owner) or not adapter.wallet.renew_coinjoin_inputs(points, owner=owner):
        raise PaymentConflict('CoinJoin input reservation expired or changed; do not retry this payment')
    for item in quote['chain_inputs']:
        txid, vout = item['outpoint'].split(':')
        coin = await adapter.backend.get_utxo(txid, int(vout))
        adapter.idle()
        if coin is None or coin.value != item['amount_sat'] or coin.scriptpubkey != item['scriptpubkey']:
            raise PaymentConflict('A reviewed CoinJoin input changed; discard this unsent review')


async def prepare(adapter, request):
    adapter.idle()
    if request['purpose'] != 'send' or request['send_max'] or request['rbf'] or request['input_utxos'] or request['bond_locktime'] is not None:
        raise PaymentConflict('CoinJoin needs a fixed amount and separate review')
    if not adapter.state.wallet_mnemonic:
        raise PaymentConflict('Unlock this Jam wallet before preparing a CoinJoin')
    registry = load_registry(adapter.wallet.data_dir, adapter.wallet.wallet_fingerprint, allow_legacy_fallback=False)
    if registry.get_bond_by_address(request['destination'].lower()) is not None:
        raise PaymentConflict('Use the separate bond funding review for a registered bond destination')
    settings = get_settings()
    kwargs = build_taker_config_kwargs(settings, adapter.state.wallet_mnemonic,
        adapter.state.wallet_bip39_passphrase, amount=request['amount_sat'], destination=request['destination'],
        mixdepth=request['jar'], fee_rate=request['fee_rate_millisat_vb'] / 1000,
        data_dir=adapter.wallet.data_dir)
    kwargs['tx_broadcast'] = 'self'
    backend = await get_backend(adapter.wallet.data_dir, force_new=True,
        mnemonic=adapter.state.wallet_mnemonic, network=adapter.wallet.network,
        passphrase=adapter.state.wallet_bip39_passphrase)
    prepared = None
    async def confirmation(**details):
        nonlocal prepared
        adapter.authorize()
        if details.get('destination') != request['destination'] or details.get('cj_amount') != request['amount_sat']:
            return False
        if details.get('stage') == 'initial':
            return bounded_int(details.get('total_fee')) <= request['max_fee_sat']
        if details.get('stage') == 'broadcast':
            prepared = await final_review(adapter, request, taker, details)
        # Never hand a signed transaction to Jam's automatic broadcast path.
        return False
    taker = None
    activated = False
    try:
        taker = Taker(wallet=adapter.wallet, backend=backend, config=TakerConfig(**kwargs), confirmation_callback=confirmation)
        adapter.idle()
        adapter.backend = backend
        adapter.state.activate_coinjoin_state(CoinjoinState.TAKER_RUNNING)
        adapter.state._taker_ref = taker
        adapter.state._taker_task = asyncio.current_task()
        activated = True
        await taker.start()
        adapter.authorize()
        await taker.do_coinjoin(amount=request['amount_sat'], destination=request['destination'], mixdepth=request['jar'])
        adapter.authorize()
        if prepared is None:
            raise PaymentConflict('CoinJoin was not prepared. Check liquidity, fees and wallet status; no direct payment was requested')
        return prepared
    finally:
        try:
            if taker is not None:
                await taker.stop(close_wallet=False)
        finally:
            try:
                await backend.close()
            finally:
                if activated and adapter.state.wallet_generation == adapter.generation:
                    adapter.state.activate_coinjoin_state(CoinjoinState.NOT_RUNNING)
                    adapter.state._taker_ref = None
                    adapter.state._taker_task = None
