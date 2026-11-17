import copy
import unittest
from datetime import datetime, timezone

from paperclip_jam.market import summarize, snapshot
from jmcore.bitcoin import calculate_relative_fee

NOW = 2_000_000_000

def offer(name, fee='100', kind='sw0absoffer'):
    return {'counterparty':name, 'ordertype':kind, 'minsize':27300, 'maxsize':10000000,
            'cjfee':fee, 'fidelity_bond_verified':True, 'fidelity_bond_verification_stale':False,
            'fidelity_bond_data':{'cert_expiry':110}}

def book(offers):
    return {'timestamp':datetime.fromtimestamp(NOW, timezone.utc).isoformat(),
            'current_block_height':100, 'directory_nodes':['synthetic'], 'offers':offers}

class MarketTests(unittest.TestCase):
    def test_fixed_and_percentage_fees_are_compared_at_same_amount(self):
        value = summarize(book([offer('a'),offer('b','0.00005','sw0reloffer')]),1000000,NOW)
        self.assertEqual(value['median_fee_sat'],'75')
        self.assertEqual(value['maker_count'],2)
        self.assertEqual(value['status'],'fresh')
        self.assertEqual(summarize(book([offer('a'),offer('b','0.00005','sw0reloffer')]),2000000,NOW)['median_fee_sat'],'100')

    def test_duplicate_offers_do_not_weight_one_maker_more(self):
        data = [offer('a','100'),offer('b','500'),offer('c','200')]+[offer('a','10000')]*100
        self.assertEqual(summarize(book(data),1000000,NOW)['median_fee_sat'],'200')
        self.assertEqual(summarize(book(data),1000000,NOW)['maker_count'],3)

    def test_relative_rounding_matches_actual_jam_fee_calculation(self):
        for amount in [30000,50000,100000,100001,125000]:
            row = summarize(book([offer('a','0.00005','sw0reloffer')]),amount,NOW)
            self.assertEqual(row['median_fee_sat'],str(calculate_relative_fee(amount,'0.00005')))
        row = summarize(book([offer('a','0'),offer('b','0.00005','sw0reloffer')]),50000,NOW)
        self.assertEqual(row['median_fee_sat'],'1')

    def test_invalid_or_unverified_offers_are_not_a_zero_fee(self):
        for field,value in [('fidelity_bond_verified',False),('fidelity_bond_verified',None),('fidelity_bond_verification_stale',True),('fidelity_bond_data',None),('fidelity_bond_data',{'cert_expiry':99}),('minsize',True),('minsize',2000000),('maxsize',999999),('cjfee','NaN'),('cjfee','123'),('ordertype','swaabsoffer')]:
            row=offer('a');row[field]=value
            result=summarize(book([row]),1000000,NOW)
            self.assertEqual((result['status'],result['median_fee_sat']),('empty',None),field)
        self.assertEqual(summarize(book([offer('a',0)]),1000000,NOW)['median_fee_sat'],'0')

    def test_stale_disconnected_malformed_and_future_books_are_unavailable(self):
        data=book([offer('a')])
        self.assertEqual(summarize(data,1000000,NOW+121)['status'],'stale')
        self.assertEqual(summarize(data,1000000,NOW-31)['status'],'unavailable')
        for changes in [{'directory_nodes':[]},{'current_block_height':None},{'timestamp':'invalid'},{'timestamp':'2030-01-01'},{'offers':[{}]*10001}]:
            changed=copy.deepcopy(data);changed.update(changes)
            self.assertEqual(summarize(changed,1000000,NOW)['status'],'unavailable')
        for amount in [True,0,27300.0,2100000000000001]:
            with self.assertRaises(ValueError): summarize(data,amount,NOW)

class MarketTransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_host_snapshot_is_bounded_and_never_follows_redirects(self):
        import json
        from unittest.mock import patch, MagicMock
        from contextlib import asynccontextmanager

        class Content:
            chunks = []
            consumed = 0
            async def iter_chunked(self, size):
                for chunk in self.chunks:
                    self.consumed += 1
                    yield chunk

        class Response:
            status = 200
            content = Content()

        response = Response()
        @asynccontextmanager
        async def get(url, **kwargs):
            self.assertEqual(url, 'http://watcher.invalid/orderbook.json')
            self.assertFalse(kwargs['allow_redirects'])
            yield response
        client = MagicMock()
        client.get = get
        client.__aenter__.return_value = client
        state = object()
        with patch('paperclip_jam.market._get_obwatch_url', return_value='http://watcher.invalid'), \
                patch('paperclip_jam.market.aiohttp.ClientSession', return_value=client) as session, \
                patch('paperclip_jam.market.time.time', return_value=NOW):
            response.content.chunks = [json.dumps(book([offer('a')])).encode()]
            self.assertEqual((await snapshot(state,1000000))['median_fee_sat'],'100')
            self.assertFalse(session.call_args.kwargs['trust_env'])
            self.assertEqual(session.call_args.kwargs['timeout'].total,10)
            for code in [302,401,500]:
                response.status = code
                response.content.consumed = 0
                self.assertEqual((await snapshot(state,1000000))['status'],'unavailable')
                self.assertEqual(response.content.consumed,0)
            response.status = 200
            response.content.chunks = [b'x' * 65536] * 40
            response.content.consumed = 0
            self.assertEqual((await snapshot(state,1000000))['status'],'unavailable')
            self.assertEqual(response.content.consumed,33)
            response.content.chunks = [b'not-json']
            self.assertEqual((await snapshot(state,1000000))['status'],'unavailable')

if __name__ == '__main__': unittest.main()
