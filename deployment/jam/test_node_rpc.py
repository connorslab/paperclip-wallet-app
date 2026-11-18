"""Real restricted native child, synthetic nodes, no funded wallet state."""
import base64
import asyncio
import concurrent.futures
import hashlib
from http.server import BaseHTTPRequestHandler
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

import httpx
from jmcore.settings import JoinMarketSettings
from paperclip_jam import node_store
from paperclip_jam.node_rpc import NativeFilter
from paperclip_jam.node_owner import owned_node
from test_node_setup import NodeFixture, ONION, TIP

if os.name == 'nt':
    from windows import private_storage as native

ENTRY = Path(__file__).with_name('desktop-entry.py').resolve()
WALLET = 'jm_12345678_mainnet'


class NativeRPC(NodeFixture):
    def rpc_node(self, context=None):
        owner = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args): pass
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                owner.calls.append((body, self.path, self.headers.get('Authorization')))
                time.sleep(owner.delay)
                if owner.status == -1:
                    self.connection.shutdown(socket.SHUT_RDWR); self.connection.close(); return
                def reply(call):
                    method = call['method']
                    result = ({'chain':'main','blocks':961650,'bestblockhash':TIP,'difficulty_blake2b':1,
                        'initialblockdownload':False} if method == 'getblockchaininfo'
                        else {'hash':TIP,'height':961650,'header_version':2} if method == 'getblockheader'
                        else [WALLET, 'foreign-wallet'] if method == 'listwallets'
                        else 'synthetic-result')
                    return {'id':call['id'], 'result':result, 'error':None}
                value = [reply(c) for c in reversed(body)] if isinstance(body, list) else reply(body)
                data = json.dumps(owner.rewrite(value)).encode()
                self.send_response(owner.status)
                for k,v in owner.extra_headers.items(): self.send_header(k,v)
                self.send_header('Content-Length',str(len(data))); self.end_headers()
                try: self.wfile.write(data)
                except (BrokenPipeError,ConnectionResetError): pass
        return self.serve(Handler, context)

    def filtered(self, settings, socks=None):
        value = NativeFilter(settings, 'local', 'local-token', socks)
        self.addCleanup(value.client.close)
        return value

    def request(self, method, identity=1, **extras):
        return dict(jsonrpc='2.0', method=method, id=identity, **extras)

    def test_reviewed_policy_source_is_unchanged(self):
        path = Path(__file__).parent / 'paperclip_jam/vendor/rpc_filter.py'
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),
            '444fedcbab403843dcf4bce0b1a22bd57bf33d98983d72cfa95841d51bf094d8')

    def test_single_and_reordered_batch_are_bound_to_methods(self):
        port = self.rpc_node(); flt = self.filtered(self.settings(f'http://127.0.0.1:{port}'))
        status, reply = flt.handle('/', json.dumps(self.request('listwallets')).encode())
        self.assertEqual(status,200); self.assertEqual(reply['result'],[WALLET])
        calls = [self.request('getblockchaininfo',1), self.request('listwallets',1), self.request('dumpwallet',2)]
        status, replies = flt.handle('/',json.dumps(calls).encode())
        self.assertEqual(status,200)
        self.assertEqual(replies[0]['result']['chain'],'main')
        self.assertEqual(replies[1]['result'],[WALLET])
        self.assertIn('error',replies[2])
        self.assertEqual([x['method'] for x in self.calls[-1][0]],['getblockchaininfo','listwallets'])
        self.assertEqual([x['id'] for x in replies],[1,1,2])

    def test_wrong_wallet_path_methods_and_ambiguous_reply_are_rejected(self):
        port = self.rpc_node(); flt = self.filtered(self.settings(f'http://127.0.0.1:{port}'))
        for path,call in [('/wallet/other',self.request('listunspent')),
                ('/?node=other',self.request('getblockchaininfo')),('/',self.request('listunspent')),
                ('/',self.request('createwallet',params=['other'])),('/',self.request('stop'))]:
            flt.handle(path,json.dumps(call).encode())
        self.assertEqual(self.calls,[])
        flt.handle('/wallet/'+WALLET,json.dumps(self.request('listunspent')).encode())
        self.assertEqual(self.calls[-1][1],'/wallet/'+WALLET)
        self.rewrite = lambda _value: [{'id':'unknown','result':['foreign-wallet']}]
        status, reply = flt.handle('/',json.dumps(self.request('listwallets')).encode())
        self.assertEqual(status,502); self.assertNotIn('foreign-wallet',json.dumps(reply))

    def test_tls_and_owned_socks_preserve_verification(self):
        context,pem = self.tls(); port=self.rpc_node(context)
        call=json.dumps(self.request('listwallets')).encode()
        for settings in [self.settings(f'https://localhost:{port}'),
                self.settings(f'https://127.0.0.1:{port}',ca_pem=pem)]:
            with self.assertRaises(OSError): self.filtered(settings).handle('/',call)
        self.assertEqual(self.calls,[])
        socks,seen=self.socks(port)
        flt=self.filtered(self.settings(f'https://{ONION}:8332',ca_pem=pem,tor=True),socks)
        self.assertEqual(flt.handle('/',call)[1]['result'],[WALLET])
        self.assertEqual(seen,[(ONION,8332)])
        self.assertEqual(self.calls[-1][2],'Basic '+base64.b64encode(b'fixture:synthetic-secret').decode())

    def test_failed_submissions_are_never_replayed(self):
        port=self.rpc_node(); flt=self.filtered(self.settings(f'http://127.0.0.1:{port}'))
        call=json.dumps(self.request('sendrawtransaction',params=['synthetic-tx'])).encode()
        for status in [401,302,-1]:
            self.status=status; self.calls.clear(); self.extra_headers={'Location':'http://127.0.0.1:1'}
            with self.assertRaises(OSError): flt.handle('/',call)
            self.assertEqual(len(self.calls),1)

    def launch(self, root, mode='--serve-node'):
        executable=os.environ.get('PAPERCLIP_NODE_CHECK_EXECUTABLE')
        command=[executable] if executable else [sys.executable,'-I',str(ENTRY)]
        child=subprocess.Popen(command+([mode] if mode else [])+['--data-dir',str(root)],stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        def close():
            if child.poll() is None:
                child.stdin.close()
                try: child.wait(timeout=6)
                except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=3)
            child.stdout.close(); child.stderr.close()
        self.addCleanup(close)
        # A bounded reader works on Windows pipes as well as POSIX.
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future=pool.submit(child.stdout.readline)
            try: line=future.result(timeout=25)
            except TimeoutError:
                child.kill(); child.wait(timeout=3); raise
        self.assertNotIn(b'synthetic-secret',line)
        return child,json.loads(line)

    def private_root(self):
        root=self.root/'jars'
        if os.name=='nt': native.private_directory(root)
        else: root.mkdir(mode=0o700)
        return root

    def test_owned_child_authentication_and_parent_lifetime(self):
        root=self.private_root(); port=self.rpc_node()
        saved=node_store.save_initial(root,self.settings(f'http://127.0.0.1:{port}'))
        before=(root/node_store.NAME).read_bytes()
        child,ready=self.launch(root)
        self.assertEqual(ready['connection_id'],saved['connection_id'])
        endpoint=f'http://127.0.0.1:{ready["port"]}'
        with httpx.Client(trust_env=False) as client:
            self.assertEqual(client.post(endpoint,json=self.request('listwallets')).status_code,401)
            response=client.post(endpoint,json=self.request('listwallets'),auth=(ready['username'],ready['password']))
        self.assertEqual(response.json()['result'],[WALLET])
        child.stdin.close(); self.assertEqual(child.wait(timeout=6),0)
        self.assertNotIn(b'synthetic-secret',child.stderr.read())
        with self.assertRaises(OSError): socket.create_connection(('127.0.0.1',ready['port']),timeout=1)
        self.assertEqual((root/node_store.NAME).read_bytes(),before)

    def test_owner_reports_child_crash_and_uses_only_restricted_credentials(self):
        root=self.private_root(); port=self.rpc_node()
        node_store.save_initial(root,self.settings(f'http://127.0.0.1:{port}'))
        async def check():
            with self.assertRaises(ValueError):
                async with owned_node(root,None,dict(os.environ)) as child:
                    with patch.dict(os.environ,dict(child.node_environment,JOINMARKET_DATA_DIR=str(root)),clear=True):
                        settings=JoinMarketSettings().bitcoin
                    self.assertNotEqual(settings.rpc_url,f'http://127.0.0.1:{port}')
                    self.assertEqual(settings.rpc_user,'paperclip-native')
                    self.assertNotEqual(settings.rpc_password.get_secret_value(),'synthetic-secret')
                    child.kill(); await child.wait()
        asyncio.run(check())

    def test_parent_close_during_submission_does_not_replay_or_leave_listener(self):
        root=self.private_root(); port=self.rpc_node()
        node_store.save_initial(root,self.settings(f'http://127.0.0.1:{port}'))
        child,ready=self.launch(root); self.calls.clear(); self.delay=2
        def submit():
            try:
                with httpx.Client(trust_env=False,timeout=4) as client:
                    return client.post(f'http://127.0.0.1:{ready["port"]}',
                        auth=(ready['username'],ready['password']),
                        json=self.request('sendrawtransaction',params=['synthetic-tx']))
            except httpx.HTTPError:
                return None
        with concurrent.futures.ThreadPoolExecutor() as pool:
            request=pool.submit(submit)
            deadline=time.monotonic()+3
            while not self.calls and time.monotonic()<deadline: time.sleep(0.02)
            self.assertEqual(len(self.calls),1)
            child.stdin.close(); self.assertEqual(child.wait(timeout=5),0)
            self.assertIsNone(request.result(timeout=5))
        self.assertEqual(len(self.calls),1)
        with self.assertRaises(OSError): socket.create_connection(('127.0.0.1',ready['port']),timeout=1)

    def test_jars_launch_activates_saved_connection_without_default_fallback(self):
        root=self.private_root(); port=self.rpc_node()
        node_store.save_initial(root,self.settings(f'http://127.0.0.1:{port}'))
        child,ready=self.launch(root,mode=None)
        self.assertEqual(set(ready),{'ready','endpoint'}); self.assertTrue(ready['ready'])
        self.assertEqual([c[0]['method'] for c in self.calls[:2]],['getblockchaininfo','getblockheader'])
        child.stdin.close(); code=child.wait(timeout=10); errors=child.stderr.read()
        self.assertEqual(code,0,errors.decode())
        self.assertNotIn(b'synthetic-secret',errors)


if __name__=='__main__': unittest.main()
