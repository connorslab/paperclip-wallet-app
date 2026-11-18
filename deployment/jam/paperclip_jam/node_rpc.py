"""Owned native RPC child. Node credentials stay behind the reviewed filter.

Native children run as the same OS user; this is a client permission boundary,
not an OS sandbox against a compromised process with that user's file access.
"""
import asyncio
import json
import logging
import os
import secrets
import sys
import threading
import time
from http.server import ThreadingHTTPServer

import httpx
from rpc_batch import install
from paperclip_jam import node_store
from paperclip_jam.node_setup import NodeSetupError, verify
from paperclip_jam.vendor import rpc_filter as policy

install(vars(policy))
MAX_REPLY = 64 * 1024 * 1024


class NativeFilter(policy.Filter):
    def __init__(self, settings, user, password, socks_port):
        # Upstream's constructor only accepts HTTP; its transport is replaced
        # below. The placeholder is never contacted or used for authentication.
        super().__init__('http://127.0.0.1:1', None, user, password, mode='enforce')
        if settings.tor and (type(socks_port) is not int or not 1 <= socks_port <= 65535):
            raise NodeSetupError('tor_required')
        self.endpoint = settings.endpoint.rstrip('/')
        self.client = httpx.Client(verify=settings.tls_context(), trust_env=False,
            follow_redirects=False, proxy=f'socks5h://127.0.0.1:{socks_port}' if settings.tor else None,
            auth=(settings.username, settings.password), headers={'Accept-Encoding': 'identity'},
            timeout=httpx.Timeout(21600, connect=10, write=30, pool=10))

    def _log_denied(self, *_args):
        pass  # Do not echo client-controlled method names or paths into logs.

    def forward(self, path, body):
        # Path comes only from the reviewed filter, never a client-selected URL.
        try:
            with self.client.stream('POST', self.endpoint + path, content=body,
                    headers={'Content-Type': 'application/json'}) as response:
                if (response.status_code not in (200, 400, 404, 500)
                        or response.headers.get('Content-Encoding', 'identity').lower() != 'identity'):
                    raise OSError('Node result unavailable')
                result = bytearray()
                deadline = time.monotonic() + 21600
                for chunk in response.iter_bytes():
                    if len(result) + len(chunk) > MAX_REPLY or time.monotonic() > deadline:
                        raise OSError('Node result unavailable')
                    result.extend(chunk)
                return response.status_code, bytes(result), 'application/json'
        except (httpx.HTTPError, OSError):
            # A request might already have executed. Never replay it, including
            # after authentication failure, redirect or lost response.
            raise OSError('Node result unavailable; inspect status before retrying') from None

    def handle(self, path, body):
        valid, wallet = policy.parse_path(path)
        if (not valid or '?' in path or '#' in path
                or (wallet is not None and not policy.is_jm_wallet(wallet))):
            return 404, policy.error_obj(None, policy.ERR_NOT_ALLOWED, 'RPC path not allowed')
        try:
            calls = json.loads(body)
        except (ValueError, UnicodeError):
            return 400, policy.error_obj(None, policy.ERR_PARSE, 'Invalid RPC request')
        batch = isinstance(calls, list)
        target = '/' if wallet is None else '/wallet/' + wallet
        # Apply method-bound response validation to single calls too. No raw
        # malformed response can bypass wallet-list filtering.
        status, replies = self._handle_batch(calls if batch else [calls], wallet, target)
        return status, replies if batch or not isinstance(replies, list) else (replies[0] if replies else b'')


def run(root, socks_port=None):
    logging.disable(logging.CRITICAL)
    stored = node_store.load(root)
    if stored is None:
        raise NodeSetupError('invalid_settings')
    asyncio.run(verify(stored.settings, socks_port))
    user, password = 'paperclip-native', secrets.token_hex(32)
    filtered = NativeFilter(stored.settings, user, password, socks_port)
    stopping = threading.Event()
    parent = threading.Thread(target=lambda: (os.read(0, 1), stopping.set()), daemon=True)
    handler = policy.make_handler(filtered)

    class Handler(handler):
        def setup(self):
            super().setup()
            self.connection.settimeout(30)

    class Server(ThreadingHTTPServer):
        # In-flight requests are not replayed when the parent disappears. Their
        # owner must reconcile its durable payment/rescan state on next startup.
        daemon_threads = True
        block_on_close = False

        def handle_error(self, *_args):
            pass  # No arbitrary exceptions or request data in stderr.

    try:
        with Server(('127.0.0.1', 0), Handler) as server:
            server.timeout = 0.1
            parent.start()
            print(json.dumps({'ready': True, 'port': server.server_port, 'username': user,
                'password': password, 'connection_id': stored.connection_id}), flush=True)
            while not stopping.is_set():
                server.handle_request()
    finally:
        filtered.client.close()

