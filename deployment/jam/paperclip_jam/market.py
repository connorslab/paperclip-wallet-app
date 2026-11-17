"""Read-only, bounded fee comparison from this host's orderbook watcher.

No remote fee website, no wallet data and no maker configuration changes. Count
one cheapest eligible offer per maker at the requested amount, so repeated offers
from one maker do not dominate the median. These are advertisements, not earnings.
"""
import json
import time
from datetime import datetime
from decimal import Decimal, InvalidOperation

import aiohttp
from jmcore.fee_quantization import QUANT_ABS, QUANT_REL
from jmcore.bitcoin import calculate_relative_fee
from jmwalletd.routers.obwatch import _get_obwatch_url

MAX_MONEY = 2_100_000_000_000_000
MAX_AGE = 120


def integer(value, low=0, high=MAX_MONEY):
    return type(value) is int and low <= value <= high


def summarize(book, amount, now=None):
    now = int(time.time()) if now is None else now
    if not integer(amount, 27_300):
        raise ValueError('Invalid comparison amount')
    result = {'amount_sat': amount, 'fetched_at': now, 'book_updated_at': None,
              'status': 'unavailable', 'maker_count': 0, 'median_fee_sat': None}
    if not isinstance(book, dict) or not isinstance(book.get('offers'), list) or len(book['offers']) > 10_000:
        return result
    try:
        stamp = datetime.fromisoformat(book['timestamp'].replace('Z', '+00:00'))
        if stamp.tzinfo is None:
            return result
        updated = int(stamp.timestamp())
    except (KeyError, TypeError, ValueError, AttributeError, OverflowError):
        return result
    if updated > now + 30:
        return result
    result['book_updated_at'] = updated
    if now - updated > MAX_AGE:
        return dict(result, status='stale')
    height = book.get('current_block_height')
    if not integer(height, 1, 0xffffffff) or not isinstance(book.get('directory_nodes'), list) or not book['directory_nodes']:
        return result
    prices = {}
    for offer in book['offers']:
        if not isinstance(offer, dict):
            continue
        maker, bond = offer.get('counterparty'), offer.get('fidelity_bond_data')
        if not isinstance(maker, str) or not 1 <= len(maker) <= 256 or not isinstance(bond, dict):
            continue
        if offer.get('fidelity_bond_verified') is not True or offer.get('fidelity_bond_verification_stale') is not False:
            continue
        if not integer(bond.get('cert_expiry'), height, 0xffffffff):
            continue
        if not integer(offer.get('minsize')) or not integer(offer.get('maxsize')) or not offer['minsize'] <= amount <= offer['maxsize']:
            continue
        # Compare maker fees before mining contributions; never present this as
        # the taker's total cost. Do not count malformed, non-grid or legacy fees.
        raw = offer.get('cjfee')
        if type(raw) is int and integer(raw):
            raw = str(raw)
        if not isinstance(raw, str) or len(raw) > 24:
            continue
        try:
            fee = Decimal(raw)
            if not fee.is_finite():
                continue
            if offer.get('ordertype') == 'sw0absoffer' and fee in QUANT_ABS:
                sats = int(fee)
            elif offer.get('ordertype') == 'sw0reloffer' and fee in QUANT_REL:
                sats = calculate_relative_fee(amount, str(fee))
            else:
                continue
        except (InvalidOperation, ValueError, OverflowError):
            continue
        prices[maker] = min(sats, prices.get(maker, sats))
    fees = sorted(prices.values())
    if not fees:
        return dict(result, status='empty')
    middle = len(fees) // 2
    median = Decimal(fees[middle]) if len(fees) % 2 else Decimal(fees[middle - 1] + fees[middle]) / 2
    return dict(result, status='fresh', maker_count=len(fees), median_fee_sat=format(median, 'f'))


async def snapshot(state, amount):
    unavailable = summarize({}, amount)
    try:
        async with aiohttp.ClientSession(trust_env=False, timeout=aiohttp.ClientTimeout(total=10)) as client:
            async with client.get(_get_obwatch_url(state) + '/orderbook.json', allow_redirects=False) as response:
                if response.status != 200:
                    return unavailable
                data = bytearray()
                async for chunk in response.content.iter_chunked(65536):
                    data.extend(chunk)
                    if len(data) > 2 * 1024 * 1024:
                        return unavailable
                return summarize(json.loads(data), amount)
    except (aiohttp.ClientError, TimeoutError, ValueError):
        return unavailable
