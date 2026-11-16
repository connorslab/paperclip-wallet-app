#!/usr/bin/env python3
"""Unfunded native daemon prerequisite; this is not installer/signing acceptance.

Build paperclip-walletd with barkd-web-ui and BARK_WEB_DIST, then pass --binary.
Uses a fresh private directory, loopback only, and never prints authentication.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener, ProxyHandler


def check(binary):
    with tempfile.TemporaryDirectory(prefix='paperclip-native-qa-') as temporary:
        root = Path(temporary)
        data = root / 'wallet'
        data.mkdir(mode=0o700)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        endpoint = f'http://127.0.0.1:{port}'
        # Do not inherit real node/Jam credentials, platform overrides or proxies.
        env = {key: os.environ[key] for key in
               ('PATH', 'HOME', 'SYSTEMROOT', 'WINDIR', 'TEMP', 'TMP', 'TMPDIR') if key in os.environ}
        env.update(BARKD_DATADIR=str(data), BARKD_BIND_HOST='127.0.0.1',
                   BARKD_BIND_PORT=str(port), BARKD_UI_DEFAULT_NETWORK='regtest',
                   BARKD_UI_DEFAULT_ARK_SERVER='http://127.0.0.1:1',
                   BARKD_UI_DEFAULT_CHAIN_SOURCE='http://127.0.0.1:1')
        http = build_opener(ProxyHandler({}))

        def request(path, token=None, origin=None, method=None, body=None):
            headers = {}
            if token is not None:
                headers['Authorization'] = 'Bearer ' + token
            if origin:
                headers.update(Origin=origin, **{'Access-Control-Request-Method':'POST',
                    'Access-Control-Request-Headers':'authorization,content-type'})
            if body is not None:
                headers['Content-Type'] = 'application/json'
            with http.open(Request(endpoint + path, headers=headers, method=method,
                                   data=json.dumps(body).encode() if body is not None else None), timeout=3) as response:
                return response.read(), response.headers

        initial_token = None
        for run in range(2):
            with (root / f'private-daemon-{run}.log').open('wb') as log:
                process = subprocess.Popen([str(binary), '--quiet', '--no-logfile'], env=env,
                    stdout=log, stderr=log,
                    creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == 'nt' else 0)
                try:
                    for _ in range(120):
                        if process.poll() is not None:
                            raise AssertionError('Native daemon exited before readiness; logs remain private')
                        try:
                            token = (data / 'auth_token').read_text()
                            body, _ = request('/api/v1/wallet', token)
                            assert json.loads(body) == {'fingerprint': None}, 'QA unexpectedly loaded a wallet'
                            break
                        except (FileNotFoundError, URLError, TimeoutError):
                            time.sleep(0.1)
                    else:
                        raise AssertionError('Native daemon did not become ready')
                    if initial_token is None:
                        initial_token = token
                    assert token == initial_token, 'Restart replaced the existing authentication'
                    if os.name != 'nt':
                        assert data.stat().st_mode & 0o777 == 0o700, 'Wallet directory is not private'
                        assert (data / 'auth_token').stat().st_mode & 0o777 == 0o600, 'Authentication file is not private'
                    for credential in (None, 'invalid-synthetic-token'):
                        try:
                            request('/api/v1/wallet', credential)
                            raise AssertionError('Unauthenticated wallet access was accepted')
                        except HTTPError as error:
                            assert error.code == 401, 'Unexpected authentication response'
                    assert json.loads(request('/api/ui-platform')[0]) == {'platform':'standalone'}
                    assert b'id="jam-create"' in request('/')[0], 'Shared Jars setup UI missing'
                    assert b"call('backup_wallet'" in request('/joinblaket.js')[0], 'Shared backup flow missing'
                    assert json.loads(request('/api/v1/joinblaket/connection', token)[0])['configured'] is False
                    options = json.loads(request('/api/v1/wallet/creation-options', token)[0])
                    assert options['version'] == 1 and options['methods'] == ['system', 'dice']
                    assert options['words'] == [12, 24] and options['dice_sides'] == [6, 12, 20]
                    # Invalid entropy must fail before keys, configuration or RPC
                    # access. These predictable inputs are not real seed material.
                    for generation, expected in [
                            (None, 400),
                            ({'method':'dice', 'words':24, 'sides':6, 'rolls':[1],
                              'fair_dice_acknowledged':True}, 400),
                            ({'method':'system', 'words':15}, 400),
                            ({'method':'unknown', 'words':24}, 422)]:
                        try:
                            request('/api/v1/wallet/create-with-entropy', token, method='POST',
                                    body={'network':'regtest', 'seed_generation':generation})
                            raise AssertionError('Invalid entropy created a wallet or silently used random generation')
                        except HTTPError as error:
                            assert error.code == expected, 'Unexpected entropy rejection'
                        assert json.loads(request('/api/v1/wallet', token)[0]) == {'fingerprint':None}
                    try:
                        _, headers = request('/api/v1/wallet', origin='https://untrusted.example', method='OPTIONS')
                        assert headers.get('Access-Control-Allow-Origin') is None, 'Unexpected cross-origin access'
                    except HTTPError as error:
                        assert error.code in (401, 403, 405), 'Unexpected preflight response'
                    assert not (data / 'mnemonic').exists(), 'First launch unexpectedly created wallet keys'
                finally:
                    if process.poll() is None:
                        if os.name == 'nt':
                            process.send_signal(signal.CTRL_BREAK_EVENT)
                        else:
                            process.terminate()
                        try:
                            process.wait(timeout=20)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
                            raise AssertionError('Native daemon did not shut down gracefully') from None
                assert process.returncode == 0, 'Native shutdown failed'
    print('PASS native daemon: isolated first launch, authenticated shared UI, entropy rejection, origin boundary, private files and restart preservation; no wallet or payment created')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    if not binary.is_file():
        parser.error('--binary must be a built paperclip-walletd executable')
    check(binary)
