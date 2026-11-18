import importlib.util
from pathlib import Path
import tempfile
import threading
import urllib.request
import urllib.error
import base64
import json
from decimal import Decimal
import unittest
from unittest.mock import patch
import io
import os
import shutil
import ssl
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

spec = importlib.util.spec_from_file_location('pruned', Path(__file__).with_name('pruned_rpc.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Node:
    def __init__(self):
        self.blocks = [self.block(0, 'a0', None, ['t0']), self.block(1, 'a1', 'a0', ['t1'])]
        self.unavailable = set()
        self.fetches = []
        self.peers = [{'id': 7, 'services': '0000000000000009'}]

    def block(self, height, blockhash, previous, txs):
        return dict(height=height, hash=blockhash, previousblockhash=previous, tx=txs)

    def call(self, method, args=()):
        if method == 'getblockchaininfo':
            return dict(chain='regtest', blocks=len(self.blocks)-1, bestblockhash=self.blocks[-1]['hash'], initialblockdownload=False)
        if method == 'getblockhash':
            return self.blocks[args[0]]['hash']
        if method == 'getpeerinfo':
            return self.peers
        if method == 'getblockfrompeer':
            self.fetches.append(args[0])
            self.unavailable.discard(args[0])
            return {}
        if method in ('getblock', 'getblockheader'):
            b = next((b for b in self.blocks if b['hash'] == args[0]), None)
            if b is None:
                return {'confirmations': -1}
            if method == 'getblockheader':
                return dict(b, confirmations=len(self.blocks)-b['height'])
            if b['hash'] in self.unavailable:
                raise module.RpcError(-1, 'Block not available (pruned data)')
            return b
        if method == 'getrawtransaction':
            if len(args) < 3:
                raise module.RpcError(-5, 'No such transaction')
            return dict(txid=args[0], blockhash=args[2], hex='00', confirmations=1)
        if method == 'getindexinfo':
            return {}
        if method == 'decoderawtransaction':
            return {'txid': args[0], 'vin': [{'txid': 't1' if args[0] == 'child' else 'unknown'}]}
        raise AssertionError(method)


class TransportTests(unittest.TestCase):
    def response(self, body, status=200):
        response = io.BytesIO(body)
        response.status = status
        return response

    def call(self, responses, method='estimatesmartfee'):
        with tempfile.TemporaryDirectory() as directory:
            cookie = Path(directory) / 'cookie'
            cookie.write_text('user:password')
            with patch.object(module.urllib.request.OpenerDirector, 'open', side_effect=responses) as request:
                with patch.object(module.time, 'sleep'):
                    result = module.Node('http://localhost', cookie).call(method, [3])
                return result, request.call_count

    def test_busy_fee_query_retries_and_keeps_exact_amount(self):
        result, count = self.call([
            self.response(b'<html>busy</html>', 503),
            self.response(b'{"result":{"feerate":0.00001000},"error":null}'),
        ])
        self.assertEqual(result['feerate'], Decimal('0.00001000'))
        self.assertEqual(count, 2)

    def test_exhausted_busy_query_is_unavailable_not_invalid_request(self):
        with self.assertRaises(module.RpcError) as error:
            self.call([self.response(b'busy', 503) for _ in range(3)])
        self.assertEqual(error.exception.code, -28)

    def test_broadcast_is_never_retried(self):
        with tempfile.TemporaryDirectory() as directory:
            cookie = Path(directory) / 'cookie'
            cookie.write_text('user:password')
            with patch.object(module.urllib.request.OpenerDirector, 'open', return_value=self.response(b'busy', 503)) as request:
                with self.assertRaises(module.RpcError):
                    module.Node('http://localhost', cookie).call('sendrawtransaction', ['00'])
                self.assertEqual(request.call_count, 1)

    def test_html_upstream_failure_is_unavailable(self):
        with self.assertRaises(module.RpcError) as error:
            self.call([self.response(b'<html>error</html>', 500)])
        self.assertEqual(error.exception.code, -28)

    def test_upstream_rpc_errors_are_preserved(self):
        with self.assertRaises(module.RpcError) as error:
            self.call([self.response(b'{"result":null,"error":{"code":-5,"message":"missing"}}', 500)])
        self.assertEqual(error.exception.code, -5)


class NetworkTransportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cookie = self.root / 'cookie'
        self.cookie.write_text('fixture:synthetic-password')

    def serve(self, status=200, location=None, context=None):
        calls = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args): pass

            def do_GET(self):
                self.respond()

            def do_POST(self):
                self.respond()

            def respond(self):
                body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
                calls.append((self.command, self.headers.get('Authorization'), body))
                if status == 'disconnect':
                    self.close_connection = True
                    return
                encoded = b'{"result":true,"error":null}'
                self.send_response(200 if status == 'truncate' else status)
                if location is not None:
                    self.send_header('Location', location)
                self.send_header('Content-Length', str(len(encoded) + (10 if status == 'truncate' else 0)))
                self.end_headers()
                self.wfile.write(encoded)

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        if context is not None:
            server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def close():
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)
        self.addCleanup(close)
        return server.server_port, calls

    def test_redirects_never_forward_credentials_or_repeat_broadcast(self):
        target, received = self.serve()
        for status in (301, 302, 303, 307, 308):
            with self.subTest(status=status):
                source, sent = self.serve(status, f'http://127.0.0.1:{target}/foreign')
                node = module.Node(f'http://127.0.0.1:{source}', self.cookie)
                with self.assertRaisesRegex(module.RpcError, '^Node RPC redirects are not allowed$'):
                    node.call('sendrawtransaction', ['synthetic-transaction'])
                self.assertEqual(len(sent), 1)
                self.assertEqual(sent[0][0], 'POST')
                self.assertEqual(received, [])

    def test_inherited_proxy_never_receives_node_credentials(self):
        target, received = self.serve()
        proxy, intercepted = self.serve()
        environment = {key: f'http://127.0.0.1:{proxy}' for key in
            ('http_proxy', 'https_proxy', 'all_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')}
        environment.update(no_proxy='', NO_PROXY='')
        with patch.dict(os.environ, environment), patch.object(module.urllib.request, 'proxy_bypass', return_value=False):
            node = module.Node(f'http://127.0.0.1:{target}', self.cookie)
            self.assertTrue(node.call('getblockchaininfo'))
        self.assertEqual(intercepted, [])
        self.assertEqual(len(received), 1)
        self.assertEqual(received[0][1], 'Basic ' + base64.b64encode(self.cookie.read_bytes()).decode())

    def test_cookie_rotation_uses_new_cookie_on_next_request(self):
        port, received = self.serve()
        node = module.Node(f'http://127.0.0.1:{port}', self.cookie)
        node.call('getblockchaininfo')
        self.cookie.write_text('fixture:rotated-synthetic-password')
        node.call('getblockchaininfo')
        self.assertEqual(len(received), 2)
        self.assertNotEqual(received[0][1], received[1][1])

    def test_disconnect_after_broadcast_is_unavailable_without_replay(self):
        for failure in ('disconnect', 'truncate'):
            with self.subTest(failure=failure):
                port, received = self.serve(failure)
                node = module.Node(f'http://127.0.0.1:{port}', self.cookie)
                with self.assertRaisesRegex(module.RpcError, '^Upstream chain RPC unavailable$'):
                    node.call('sendrawtransaction', ['synthetic-transaction'])
                self.assertEqual(len(received), 1)

    def test_invalid_endpoint_does_not_read_cookie_or_connect(self):
        missing = self.root / 'missing-cookie'
        for address in ('file:///private', 'ftp://example.invalid', 'http://user:synthetic@example.invalid',
                'http://example.invalid/#secret', 'http://example.invalid/\nprivate'):
            with self.subTest(address=address):
                with self.assertRaisesRegex(ValueError, '^Invalid node RPC address;'):
                    module.Node(address, missing)

    @unittest.skipUnless(shutil.which('openssl'), 'TLS fixture generation needs OpenSSL')
    def test_https_requires_trusted_certificate_and_matching_hostname(self):
        cert, key = self.root / 'cert.pem', self.root / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
            '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
            '-keyout', str(key), '-out', str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        port, received = self.serve(context=context)
        # With no trusted fixture CA, TLS fails before authorization is sent.
        with self.assertRaises(module.RpcError):
            module.Node(f'https://localhost:{port}', self.cookie).call('getblockchaininfo')
        self.assertEqual(received, [])
        trusted = ssl.create_default_context(cafile=str(cert))
        self.assertEqual(trusted.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(trusted.check_hostname)
        with patch.object(ssl, '_create_default_https_context', return_value=trusted):
            with self.assertRaises(module.RpcError):
                module.Node(f'https://127.0.0.1:{port}', self.cookie).call('getblockchaininfo')
            self.assertEqual(received, [])
            self.assertTrue(module.Node(f'https://localhost:{port}', self.cookie).call('getblockchaininfo'))
        self.assertEqual(len(received), 1)


class PrunedTests(unittest.TestCase):
    def test_rpc_amounts_remain_exact_without_exponents(self):
        source = '{"mempoolminfee":0.00001000,"vout":[{"value":0.00000001},{"value":20999999.99999999}]}'
        value = json.loads(source, parse_float=Decimal)
        encoded = module.rpc_json(value)
        self.assertEqual(json.loads(encoded, parse_float=Decimal), value)
        self.assertIn('0.00001000', encoded)
        self.assertIn('0.00000001', encoded)
        self.assertIn('20999999.99999999', encoded)
        self.assertEqual(module.rpc_json({'rate': 1e-5}), '{"rate":0.00001}')
        for invalid in (float('nan'), float('inf'), Decimal('1e999999')):
            with self.assertRaises(ValueError):
                module.rpc_json(invalid)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)/'index.sqlite'
        self.node = Node()
        self.index = module.Index(self.path, self.node, 0)

    def tearDown(self):
        self.index.db.close()
        self.temp.cleanup()

    def test_health_reports_coverage_without_starting_historical_fetch(self):
        self.node.unavailable.add('a0')
        self.assertFalse(module.dispatch(self.index, 'getpaperclipindexinfo', [])['synced'])
        self.assertEqual(self.node.fetches, [])
        self.index.sync()
        self.assertTrue(module.dispatch(self.index, 'getpaperclipindexinfo', [])['synced'])
        self.node.blocks.append(self.node.block(2, 'a2', 'a1', ['t2']))
        self.assertFalse(module.dispatch(self.index, 'getpaperclipindexinfo', [])['synced'])

    def test_reorg_removes_old_confirmation_and_cache(self):
        self.index.sync()
        self.assertEqual(self.index.transaction('t1', True)['confirmations'], 1)
        self.node.blocks[1] = self.node.block(1, 'b1', 'a0', ['t2'])
        with self.assertRaises(module.RpcError) as error:
            self.index.transaction('t1', True)
        self.assertEqual(error.exception.code, -32004)
        self.index.sync()
        with self.assertRaises(module.RpcError) as error:
            self.index.transaction('t1', True)
        self.assertEqual(error.exception.code, -32004)
        self.assertEqual(self.index.transaction('t2', True)['blockhash'], 'b1')
        self.assertEqual(self.index.db.execute('SELECT COUNT(*) FROM raw_cache WHERE txid=?', ['t1']).fetchone()[0], 0)

    def test_missing_block_retrieved_from_peer(self):
        self.node.unavailable.add('a0')
        self.assertTrue(self.index.sync()['synced'])
        self.assertEqual(self.node.fetches, ['a0'])

    def test_no_peer_stops_scan_and_never_reports_ready(self):
        self.node.peers = []
        self.node.unavailable.add('a1')
        with self.assertRaises(module.RpcError):
            self.index.sync()
        self.assertFalse(self.index.info()['synced'])
        self.assertEqual(self.index.tip()[0], 0)

    def test_restart_keeps_index_and_rejects_different_origin(self):
        self.index.sync()
        self.index.db.close()
        self.index = module.Index(self.path, self.node, 0)
        self.assertTrue(self.index.info()['synced'])
        self.assertEqual(self.index.transaction('t1'), '00')
        with self.assertRaises(ValueError):
            module.Index(self.path, self.node, 1)

    def test_unknown_transaction_is_not_reported_absent(self):
        self.index.sync()
        with self.assertRaises(module.RpcError) as error:
            self.index.transaction('not-indexed')
        self.assertEqual(error.exception.code, -32004)

    def test_no_fake_txindex_or_wallet_access(self):
        self.assertEqual(module.dispatch(self.index, 'getindexinfo', []), {})
        for method in ('sendtoaddress', 'dumpprivkey', 'stop', 'invalidateblock', 'getblockfrompeer'):
            with self.assertRaises(module.RpcError) as error:
                module.dispatch(self.index, method, [])
            self.assertEqual(error.exception.code, -32601)

    def test_negative_lookup_requires_proven_active_ancestry(self):
        self.index.sync()
        self.assertTrue(self.index.register(['child']))
        with self.assertRaises(module.RpcError) as error:
            self.index.transaction('child')
        self.assertEqual(error.exception.code, -5)
        with self.assertRaises(module.RpcError):
            self.index.register(['unrelated'])
        self.node.blocks[1] = self.node.block(1, 'b1', 'a0', ['other'])
        with self.assertRaises(module.RpcError) as error:
            self.index.transaction('child')
        self.assertEqual(error.exception.code, -32004)

    def test_wrong_block_does_not_advance_checkpoint(self):
        call = self.node.call
        def wrong(method, args=()):
            result = call(method, args)
            return dict(result, hash='wrong') if method == 'getblock' else result
        self.node.call = wrong
        with self.assertRaises(module.RpcError):
            self.index.sync()
        self.assertIsNone(self.index.tip())

    def test_mining_during_negative_lookup_is_not_absence(self):
        self.index.sync()
        self.index.register(['child'])
        call = self.node.call
        def changed(method, args=()):
            if method == 'getrawtransaction':
                self.node.blocks.append(self.node.block(2, 'a2', 'a1', ['child']))
            return call(method, args)
        self.node.call = changed
        with self.assertRaises(module.RpcError) as error:
            self.index.transaction('child')
        self.assertEqual(error.exception.code, -28)

    def test_http_authentication_and_rpc_boundaries(self):
        cookie = Path(self.temp.name)/'client.cookie'
        cookie.write_text('test:private-test-token')
        server = module.make_server(self.index, '127.0.0.1', 0, cookie)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        url = 'http://127.0.0.1:' + str(server.server_address[1])
        data = json.dumps({'id': 1, 'method': 'getindexinfo', 'params': []}).encode()
        try:
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(urllib.request.Request(url, data), timeout=2)
            self.assertEqual(error.exception.code, 401)
            headers = {'Authorization': 'Basic '+base64.b64encode(cookie.read_bytes()).decode()}
            with urllib.request.urlopen(urllib.request.Request(url, data, headers), timeout=2) as response:
                self.assertEqual(response.version, 11)
                self.assertEqual(json.load(response)['result'], {})
            data = json.dumps({'id': 2, 'method': 'sendtoaddress', 'params': []}).encode()
            with urllib.request.urlopen(urllib.request.Request(url, data, headers), timeout=2) as response:
                self.assertEqual(json.load(response)['error']['code'], -32601)
        finally:
            server.shutdown()
            server.server_close()
            worker.join()


if __name__ == '__main__':
    unittest.main()
