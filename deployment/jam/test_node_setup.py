"""Native preflight against synthetic nodes. No wallet or production RPC."""
import asyncio
import base64
import datetime
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import select
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
from paperclip_jam import node_setup as setup

TIP = 'a' * 64
PUBLIC = b'\x01' * 32
ONION = base64.b32encode(PUBLIC + hashlib.sha3_256(b'.onion checksum' + PUBLIC + b'\x03').digest()[:2] + b'\x03').decode().lower() + '.onion'


class NodeFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.calls = []
        self.status = 200
        self.rewrite = lambda value: value
        self.extra_headers = {}
        self.delay = 0

    def serve(self, handler, context=None):
        server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
        if context is not None:
            server.socket = context.wrap_socket(server.socket, server_side=True)
        return self.start(server)

    def start(self, server):
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def close():
            server.shutdown(); server.server_close(); thread.join(timeout=3)
        self.addCleanup(close)
        return server.server_address[1]

    def node(self, context=None):
        owner = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args): pass
            def do_POST(self):
                call = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                owner.calls.append((call, self.headers.get('Authorization')))
                time.sleep(owner.delay)
                result = ({'chain': 'main', 'blocks': 961650, 'bestblockhash': TIP, 'difficulty_blake2b': 1.5,
                    'initialblockdownload': False, 'pruned': True} if call['method'] == 'getblockchaininfo'
                    else {'hash': TIP, 'height': 961650, 'header_version': 2})
                body = json.dumps(owner.rewrite({'result': result, 'error': None, 'id': call['id']})).encode()
                self.send_response(owner.status)
                for key, value in owner.extra_headers.items(): self.send_header(key, value)
                self.send_header('Content-Length', str(len(body))); self.end_headers()
                try: self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError): pass
        return self.serve(Handler, context)

    def settings(self, endpoint, **extras):
        return setup.NodeSettings.parse(dict(endpoint=endpoint, username='fixture', password='synthetic-secret', **extras))

    def check(self, settings, socks_port=None):
        executable = os.environ.get('PAPERCLIP_NODE_CHECK_EXECUTABLE')
        if executable:
            command = [executable, '--check-node']
            if socks_port is not None:
                command += ['--tor-socks-port', str(socks_port)]
            payload = {key:getattr(settings, key) for key in ('endpoint', 'username', 'password', 'tor', 'ca_pem')}
            result = subprocess.run(command, input=json.dumps(payload).encode(), stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, cwd=self.root, timeout=25)
            self.assertEqual(result.stderr, b'')
            self.assertNotIn(b'synthetic-secret', result.stdout)
            value = json.loads(result.stdout)
            if not value['ready']:
                self.assertEqual(result.returncode, 2)
                raise setup.NodeSetupError(value['code'])
            self.assertEqual(result.returncode, 0)
            return value
        return asyncio.run(setup.verify(settings, socks_port))

    def tls(self):
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'localhost')])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(1).not_valid_before(now - datetime.timedelta(minutes=1))
            .not_valid_after(now + datetime.timedelta(days=1))
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost'), x509.DNSName(ONION)]), critical=False)
            .sign(key, hashes.SHA256()))
        pem = cert.public_bytes(serialization.Encoding.PEM).decode()
        (self.root / 'cert.pem').write_text(pem)
        (self.root / 'key.pem').write_bytes(key.private_bytes(serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.root / 'cert.pem', self.root / 'key.pem')
        return context, pem

    def socks(self, target):
        seen = []
        class Socks(socketserver.BaseRequestHandler):
            def handle(self):
                client = self.request
                client.settimeout(3)
                def read(count):
                    value = b''
                    while len(value) < count:
                        chunk = client.recv(count-len(value))
                        if not chunk: raise EOFError()
                        value += chunk
                    return value
                greeting = read(2)
                read(greeting[1]); client.sendall(b'\x05\x00')
                head = read(4)
                if head != b'\x05\x01\x00\x03': return
                host = read(read(1)[0]).decode()
                port = int.from_bytes(read(2), 'big')
                seen.append((host, port))
                with socket.create_connection(('127.0.0.1', target), timeout=3) as upstream:
                    client.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x01')
                    while True:
                        ready, _, _ = select.select([client, upstream], [], [], 3)
                        if not ready: return
                        for source in ready:
                            data = source.recv(65536)
                            if not data: return
                            (upstream if source is client else client).sendall(data)
        class Server(socketserver.ThreadingTCPServer):
            daemon_threads = True
        return self.start(Server(('127.0.0.1', 0), Socks)), seen



class Preflight(NodeFixture):
    def test_read_only_mainnet_preflight_and_public_result(self):
        port = self.node()
        result = self.check(self.settings(f'http://127.0.0.1:{port}'))
        self.assertEqual(result, {'ready': True, 'network': 'main', 'height': 961650, 'pruned': True})
        self.assertEqual([call[0]['method'] for call in self.calls], ['getblockchaininfo', 'getblockheader'])
        self.assertEqual(self.calls[1][0]['params'], [TIP, True])
        self.assertTrue(all(call[1] == 'Basic ' + base64.b64encode(b'fixture:synthetic-secret').decode() for call in self.calls))
        self.assertEqual(list(self.root.iterdir()), [])

    def test_rejects_unsafe_configuration_without_network(self):
        for endpoint in ['http://example.com', 'http://localhost', 'file:///secret', 'https://user:secret@node.invalid',
                'https://node.invalid/wallet/name', 'https://node.invalid/?secret', 'https://node.invalid/#secret',
                'http://' + 'a'*56 + '.onion', 'https://node.invalid:0', 'https://node.invalid/\n']:
            with self.subTest(endpoint=endpoint), self.assertRaises(setup.NodeSetupError): self.settings(endpoint)
        with self.assertRaises(setup.NodeSetupError): self.settings('http://' + ONION)
        with self.assertRaises(setup.NodeSetupError): self.settings('http://127.0.0.1', tor=True)
        with self.assertRaises(setup.NodeSetupError): self.settings('https://node.invalid', tor=1)

    def test_auth_permission_and_redirect_errors_do_not_retry_or_leak(self):
        port = self.node()
        for status, code in [(401, 'authentication'), (403, 'permission'), (302, 'redirect'), (307, 'redirect'), (503, 'unavailable')]:
            self.status = status
            self.extra_headers = {'Location': 'http://127.0.0.1:1/private-secret'}
            self.calls.clear()
            with self.assertRaises(setup.NodeSetupError) as failure:
                self.check(self.settings(f'http://127.0.0.1:{port}'))
            self.assertEqual(failure.exception.code, code)
            self.assertNotIn('secret', str(failure.exception))
            self.assertEqual(len(self.calls), 1)

    def test_wrong_chain_and_unsynchronized_node_never_reach_wallet_rpc(self):
        port = self.node()
        for change, code in [({'chain':'regtest'}, 'wrong_chain'), ({'difficulty_blake2b':None}, 'wrong_chain'),
                ({'blocks':961639}, 'wrong_chain'), ({'blocks':True}, 'wrong_chain'),
                ({'initialblockdownload':True}, 'syncing')]:
            self.calls.clear()
            self.rewrite = lambda value: {**value, 'result':{**value['result'], **change}}
            with self.assertRaises(setup.NodeSetupError) as failure:
                self.check(self.settings(f'http://127.0.0.1:{port}'))
            self.assertEqual(failure.exception.code, code)
            self.assertEqual(len(self.calls), 1)

    def test_mismatched_header_reply_and_oversized_result_are_rejected(self):
        port = self.node()
        variants = [lambda v: {**v, 'id':'wrong'}, lambda v: {**v, 'result':['secret']},
            lambda v: {**v, 'extra':'x'*(setup.MAX_REPLY+1)},
            lambda v: {**v, 'result':{**v['result'], 'header_version':1}},
            lambda v: {**v, 'result':{**v['result'], 'hash':'b'*64}}]
        for variant in variants:
            self.rewrite = variant
            with self.assertRaises(setup.NodeSetupError):
                self.check(self.settings(f'http://127.0.0.1:{port}'))

    def test_compressed_response_is_rejected(self):
        port = self.node(); self.extra_headers = {'Content-Encoding':'gzip'}
        with self.assertRaises(setup.NodeSetupError): self.check(self.settings(f'http://127.0.0.1:{port}'))
        self.assertEqual(len(self.calls), 1)

    def test_total_deadline_cancels_without_second_request(self):
        port = self.node(); self.delay = 0.3
        with patch.object(setup, 'CHECK_TIMEOUT', 0.1):
            with self.assertRaises(setup.NodeSetupError) as failure:
                asyncio.run(setup.verify(self.settings(f'http://127.0.0.1:{port}')))
        self.assertEqual(failure.exception.code, 'unavailable')
        self.assertEqual(len(self.calls), 1)

    def test_https_validation_and_explicit_ca_ignore_environment_overrides(self):
        context, pem = self.tls(); port = self.node(context)
        environment = {'SSL_CERT_FILE':str(self.root / 'cert.pem'), 'HTTPS_PROXY':'http://127.0.0.1:1'}
        with patch.dict(os.environ, environment):
            with self.assertRaises(setup.NodeSetupError): self.check(self.settings(f'https://localhost:{port}'))
            with self.assertRaises(setup.NodeSetupError): self.check(self.settings(f'https://127.0.0.1:{port}', ca_pem=pem))
            self.assertEqual(self.calls, [])
            self.assertTrue(self.check(self.settings(f'https://localhost:{port}', ca_pem=pem))['ready'])
        with self.assertRaises(setup.NodeSetupError): self.check(self.settings(f'https://localhost:{port}', ca_pem='PRIVATE KEY'))

    def test_onion_uses_remote_resolution_and_verified_tls_without_direct_fallback(self):
        context, pem = self.tls(); port = self.node(context)
        proxy, seen = self.socks(port)
        settings = self.settings(f'https://{ONION}:{port}', tor=True, ca_pem=pem)
        with self.assertRaises(setup.NodeSetupError) as failure: self.check(settings)
        self.assertEqual(failure.exception.code, 'tor_required')
        self.assertEqual(seen, [])
        self.assertTrue(self.check(settings, proxy)['ready'])
        self.assertTrue(seen and all(address == (ONION, port) for address in seen))
        self.assertEqual(len(self.calls), 2)
        self.calls.clear()
        with self.assertRaises(setup.NodeSetupError): self.check(settings, 1)
        self.assertEqual(self.calls, [])

    def test_private_pipe_mode_does_not_create_state_or_echo_secrets(self):
        port = self.node()
        executable = os.environ.get('PAPERCLIP_NODE_CHECK_EXECUTABLE')
        command = [executable] if executable else [sys.executable, '-I', str(Path(__file__).with_name('desktop-entry.py').resolve())]
        payload = dict(endpoint=f'http://127.0.0.1:{port}', username='fixture', password='synthetic-secret')
        for status in [200, 401]:
            self.status = status
            result = subprocess.run(command + ['--check-node'], input=json.dumps(payload).encode(),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=self.root, timeout=10)
            self.assertEqual(result.returncode, 0 if status == 200 else 2, result.stderr.decode())
            value = json.loads(result.stdout)
            self.assertEqual(value['ready'], status == 200)
            self.assertNotIn(b'synthetic-secret', result.stdout + result.stderr)
            self.assertEqual(result.stderr, b'')
            self.assertEqual(list(self.root.iterdir()), [])

    def test_pipe_input_is_bounded_and_secret_fields_have_no_repr(self):
        value = self.settings('https://node.invalid')
        self.assertNotIn('node.invalid', repr(value)); self.assertNotIn('synthetic-secret', repr(value))
        for data in [b'{bad-secret', b'x'*(setup.MAX_INPUT+1), b'{"endpoint": "secret"}']:
            output = io.StringIO()
            self.assertEqual(setup.check_pipe(io.BytesIO(data), output), 2)
            self.assertNotIn('secret', output.getvalue())


if __name__ == '__main__': unittest.main()
