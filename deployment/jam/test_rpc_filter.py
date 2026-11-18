"""Actual pinned RPC filter with synthetic node replies; no node or payment."""
import importlib.util
import base64
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import threading
import unittest

import install_rpc_filter

SOURCE = Path(os.environ.get('PAPERCLIP_RPC_SOURCE', '/usr/local/lib/jm-xbt/rpc_filter.py'))
OWN = 'jm_1234abcd_mainnet'
FOREIGN = 'foreign-wallet-fixture'


@unittest.skipUnless(SOURCE.is_file(), 'Requires the pinned or installed RPC filter')
class BatchPolicy(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='paperclip-rpc-policy-')
        cls.addClassCleanup(cls.temporary.cleanup)
        source = SOURCE
        if 'PAPERCLIP_RPC_SOURCE' in os.environ:
            source = Path(cls.temporary.name) / 'rpc_filter.py'
            shutil.copy2(SOURCE, source)
            shutil.copy2(Path(__file__).with_name('rpc_batch.py'), source.parent)
            install_rpc_filter.patch(source)
        # Container checks must load the installed adapter, not /tests/rpc_batch.
        # Native helper tests can already have imported the source adapter.
        # Isolate this import without weakening the installed-path assertion.
        previous = sys.modules.pop('rpc_batch', None)
        sys.path.insert(0, str(source.parent))
        try:
            spec = importlib.util.spec_from_file_location('reviewed_rpc_filter', source)
            cls.module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.module)
            cls.assert_adapter = Path(sys.modules['rpc_batch'].__file__).resolve()
            assert cls.assert_adapter == (source.parent / 'rpc_batch.py').resolve()
        finally:
            sys.path.pop(0)
            sys.modules.pop('rpc_batch', None)
            if previous is not None:
                sys.modules['rpc_batch'] = previous

    def setUp(self):
        m = self.module
        self.filter = m.Filter('http://127.0.0.1:8332', m.NodeAuth(None, 'fixture', 'fixture'), 'fixture', 'fixture')
        self.sent = []

    def node(self, transform=lambda values: list(reversed(values)), status=200):
        def forward(path, body):
            calls = json.loads(body)
            self.sent.append((path, calls))
            values = []
            for call in calls:
                if 'id' not in call and call.get('jsonrpc') == '2.0':
                    continue
                value = ([FOREIGN, OWN] if call['method'] == 'listwallets' else
                    {'wallets': [{'name': FOREIGN}, {'name': OWN}]} if call['method'] == 'listwalletdir' else {'chain': 'regtest'})
                values.append({'id': call.get('id'), 'result': value, 'error': None})
            return status, json.dumps(transform(values)).encode(), 'application/json'
        self.filter.forward = forward

    def request(self, calls, path='/'):
        return self.filter.handle(path, json.dumps(calls).encode())

    def test_reordered_wallet_lists_are_filtered_by_their_own_method(self):
        self.node()
        calls = [{'method': method, 'id': index} for index, method in
            enumerate(('getblockchaininfo', 'listwallets', 'listwalletdir'))]
        status, result = self.request(calls)
        self.assertEqual(status, 200)
        self.assertEqual([value['id'] for value in result], [0, 1, 2])
        self.assertEqual(result[0]['result'], {'chain': 'regtest'})
        self.assertEqual(result[1]['result'], [OWN])
        self.assertEqual(result[2]['result'], {'wallets': [{'name': OWN}]})
        self.assertNotIn(FOREIGN, json.dumps(result))
        self.assertEqual(len(self.sent), 1)

    def test_duplicate_and_distinct_client_id_types_never_cross_match(self):
        self.node()
        ids = [1, '1', 1, None, 1.5]
        _, result = self.request([{'method': 'listwallets', 'id': identity} for identity in ids])
        self.assertEqual([value['id'] for value in result], ids)
        sent = self.sent[0][1]
        self.assertEqual(len({call['id'] for call in sent}), len(ids))
        self.assertTrue(all(value['result'] == [OWN] for value in result))

    def test_missing_duplicate_unknown_and_malformed_replies_fail_without_replay(self):
        mutations = [lambda v: v[:1], lambda v: v + [v[0]],
            lambda v: [{**v[0], 'id': 'unknown-private-fixture'}, v[1]],
            lambda v: [v[0], None], lambda v: {'result': FOREIGN},
            lambda v: [{**v[0], 'error': {'code': -1, 'message': FOREIGN}}, v[1]],
            lambda v: [v[0], {'id': v[1]['id'], 'error': None}]]
        for mutate in mutations:
            with self.subTest(case=mutations.index(mutate)):
                self.sent.clear(); self.node(mutate)
                status, result = self.request([{'method': 'listwallets', 'id': 1}, {'method': 'getblockchaininfo', 'id': 2}])
                self.assertEqual(status, 502)
                self.assertEqual([reply['id'] for reply in result], [1, 2])
                self.assertTrue(all('Check status before retrying' in reply['error']['message'] for reply in result))
                self.assertNotIn(FOREIGN, json.dumps(result))
                self.assertNotIn('unknown-private-fixture', json.dumps(result))
                self.assertEqual(len(self.sent), 1)

    def test_notifications_and_denied_calls_do_not_shift_reply_binding(self):
        self.node()
        calls = [{'jsonrpc': '2.0', 'method': 'getblockchaininfo'},
            {'jsonrpc': '2.0', 'method': 'stop', 'id': 'denied'},
            {'method': 'listwallets', 'id': 'wallets'}]
        status, result = self.request(calls)
        self.assertEqual(status, 200)
        self.assertEqual([reply['id'] for reply in result], ['denied', 'wallets'])
        self.assertEqual(result[0]['error']['code'], -32601)
        self.assertEqual(result[1]['result'], [OWN])
        self.assertEqual([call['method'] for call in self.sent[0][1]], ['getblockchaininfo', 'listwallets'])
        self.assertNotIn('id', self.sent[0][1][0])

    def test_only_notifications_have_no_response_and_are_not_repeated(self):
        self.node()
        self.assertEqual(self.request([{'jsonrpc': '2.0', 'method': 'getblockchaininfo'}]), (204, b''))
        self.assertEqual(len(self.sent), 1)
        self.sent.clear()
        self.assertEqual(self.request([{'jsonrpc': '2.0', 'method': 'stop'}]), (204, b''))
        self.assertEqual(self.sent, [])

    def test_invalid_ids_and_foreign_wallet_paths_do_not_reach_node(self):
        self.node()
        for identity in [True, [], {}, float('nan'), float('inf')]:
            _, result = self.request([{'method': 'getblockchaininfo', 'id': identity}])
            self.assertEqual(result[0]['error']['code'], -32600)
            self.assertIsNone(result[0]['id'])
        _, result = self.request([{'method': 'listunspent', 'id': 7}], '/wallet/foreign-fixture')
        self.assertEqual(result[0]['error']['code'], -32601)
        self.assertEqual(self.sent, [])

    def test_parameters_and_wallet_scope_are_preserved(self):
        self.node()
        call = {'jsonrpc': '1.0', 'method': 'gettransaction', 'params': ['synthetic-reference', True], 'id': 'original'}
        _, result = self.request([call], '/wallet/' + OWN)
        path, sent = self.sent[0]
        self.assertEqual(path, '/wallet/' + OWN)
        self.assertEqual({k:v for k,v in sent[0].items() if k != 'id'}, {k:v for k,v in call.items() if k != 'id'})
        self.assertEqual(result[0]['id'], 'original')

    def test_authenticated_http_batch_keeps_node_authority_and_reply_scope(self):
        seen = []

        class Node(BaseHTTPRequestHandler):
            def log_message(self, *_args): pass
            def do_POST(self):
                calls = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                seen.append((self.headers.get('Authorization'), calls))
                values = [{'id': call['id'], 'result': [FOREIGN, OWN] if call['method'] == 'listwallets'
                    else {'chain': 'regtest'}, 'error': None} for call in reversed(calls)]
                encoded = json.dumps(values).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(encoded)))
                self.end_headers(); self.wfile.write(encoded)

        def serve(handler):
            server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            def close():
                server.shutdown(); server.server_close(); thread.join(timeout=2)
            self.addCleanup(close)
            return server.server_port

        node = serve(Node)
        m = self.module
        proxy = m.Filter(f'http://127.0.0.1:{node}', m.NodeAuth(None, 'node-fixture', 'node-fixture'),
            'client-fixture', 'client-fixture')
        port = serve(m.make_handler(proxy))
        packet = [{'method': 'getblockchaininfo', 'id': 1}, {'method': 'stop', 'id': 2}, {'method': 'listwallets', 'id': 3}]
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
        try:
            connection.request('POST', '/', json.dumps(packet), {'Authorization': 'Basic ' +
                base64.b64encode(b'client-fixture:client-fixture').decode(), 'Content-Type': 'application/json'})
            reply = connection.getresponse()
            self.assertEqual(reply.status, 200)
            result = json.loads(reply.read())
        finally:
            connection.close()
        self.assertEqual([value['id'] for value in result], [1, 2, 3])
        self.assertEqual(result[1]['error']['code'], -32601)
        self.assertEqual(result[2]['result'], [OWN])
        self.assertEqual(len(seen), 1)
        self.assertEqual(seen[0][0], 'Basic ' + base64.b64encode(b'node-fixture:node-fixture').decode())
        self.assertEqual([call['method'] for call in seen[0][1]], ['getblockchaininfo', 'listwallets'])


class Installer(unittest.TestCase):
    def test_unknown_source_is_not_modified(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'rpc_filter.py'
            original = b'synthetic-unreviewed-source'
            path.write_bytes(original)
            with self.assertRaises(ValueError): install_rpc_filter.patch(path)
            self.assertEqual(path.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
