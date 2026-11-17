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
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, ProxyHandler


def check(binary):
    with tempfile.TemporaryDirectory(prefix='paperclip-native-qa-') as temporary:
        root = Path(temporary)
        data = root / 'wallet'
        if os.name == 'nt':
            # Match the installer's private creation boundary, including an
            # explicit user owner when QA runs under an elevated Windows token.
            sys.path.insert(0, str(Path(__file__).parent / 'windows'))
            from private_storage import private_directory, validate_handle, read_private_file
            import win32con
            import win32file
            private_directory(data)
        else:
            data.mkdir(mode=0o700)
        def saved_text(name):
            # Python's CRT reader omits delete sharing and can race the native
            # atomic writer while its renamed staging handle is still open.
            # Match the launcher's checked native reader instead of retrying
            # permission failures or weakening the writer's handle protection.
            if os.name == 'nt':
                with read_private_file(data / name) as file:
                    return file.read().decode('utf-8')
            return (data / name).read_text()

        endpoint = None
        # Do not inherit real node/Jam credentials, platform overrides or proxies.
        env = {key: os.environ[key] for key in
               ('PATH', 'HOME', 'SYSTEMROOT', 'WINDIR', 'TEMP', 'TMP', 'TMPDIR') if key in os.environ}
        env.update(BARKD_DATADIR=str(data), BARKD_BIND_HOST='127.0.0.1',
                   BARKD_BIND_PORT='0', BARKD_UI_DEFAULT_NETWORK='regtest',
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
        for run in range(3):
            with (root / f'private-daemon-{run}.log').open('wb') as log:
                process = subprocess.Popen([str(binary), '--quiet', '--no-logfile'], env=env,
                    stdout=log, stderr=log,
                    creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == 'nt' else 0)
                try:
                    for _ in range(120):
                        if process.poll() is not None:
                            raise AssertionError('Native daemon exited before readiness; logs remain private')
                        try:
                            token = saved_text('auth_token')
                            endpoint = saved_text('barkd.url')
                            address = urlsplit(endpoint)
                            assert address.scheme == 'http' and address.hostname == '127.0.0.1', 'Unexpected discovery host'
                            assert address.port and address.port > 0, 'Discovery did not report the OS-assigned listen port'
                            assert not address.username and not address.password and not address.query and not address.fragment
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
                    else:
                        for name in ('auth_token', 'barkd.url'):
                            handle = win32file.CreateFile(str(data / name), win32con.READ_CONTROL,
                                win32con.FILE_SHARE_READ | win32con.FILE_SHARE_WRITE | win32con.FILE_SHARE_DELETE, None,
                                win32con.OPEN_EXISTING, win32file.FILE_FLAG_OPEN_REPARSE_POINT, None)
                            try:
                                validate_handle(handle, directory=False)
                            finally:
                                handle.Close()
                    for credential in (None, 'invalid-synthetic-token'):
                        try:
                            request('/api/v1/wallet', credential)
                            raise AssertionError('Unauthenticated wallet access was accepted')
                        except HTTPError as error:
                            assert error.code == 401, 'Unexpected authentication response'
                    assert json.loads(request('/api/ui-platform')[0]) == {'platform':'standalone'}
                    for route in ('new', 'redeem'):
                        try:
                            request('/api/desktop/handoff/' + route, token, method='POST', body={'code':'synthetic'})
                            raise AssertionError('Unmanaged daemon exposed desktop handoff')
                        except HTTPError as error:
                            assert error.code in (404, 405), 'Desktop handoff must remain absent by default'
                    assert b'id="jam-create"' in request('/')[0], 'Shared Jars setup UI missing'
                    jars_script = request('/joinblaket.js')[0]
                    assert b"call('backup_wallet'" in jars_script, 'Shared backup flow missing'
                    assert b"call('bonds')" in jars_script, 'Shared bond withdrawal flow missing'
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
                    # A different listen port must not bypass the datadir lock or
                    # overwrite the running service's discovery/authentication.
                    with socket.socket() as sock:
                        sock.bind(('127.0.0.1', 0))
                        other_port = sock.getsockname()[1]
                    with (root / f'private-duplicate-{run}.log').open('wb') as duplicate_log:
                        duplicate = subprocess.Popen([str(binary), '--quiet', '--no-logfile'],
                            env={**env, 'BARKD_BIND_PORT':str(other_port)},
                            stdout=duplicate_log, stderr=duplicate_log)
                        try:
                            assert duplicate.wait(timeout=10) != 0, 'A second daemon accepted the same data directory'
                        finally:
                            if duplicate.poll() is None:
                                duplicate.kill(); duplicate.wait(timeout=5)
                    assert b'another barkd is already running' in (root / f'private-duplicate-{run}.log').read_bytes(), 'Duplicate failed for a reason other than the instance lock'
                    assert saved_text('barkd.url') == endpoint, 'Duplicate launch replaced discovery address'
                    assert saved_text('auth_token') == token, 'Duplicate launch replaced authentication'
                    assert json.loads(request('/api/v1/wallet', token)[0]) == {'fingerprint':None}
                    # Exercise OS lock release, not just graceful cleanup. The
                    # following iteration must recover without deleting files.
                    if run == 1:
                        process.kill()
                        process.wait(timeout=10)
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
                if run == 1:
                    assert process.returncode != 0, 'Crash simulation did not terminate the process'
                else:
                    assert process.returncode == 0, 'Native shutdown failed'

        # A fixed-port bind failure must not replace the last valid discovery
        # address. The bound socket belongs only to this unfunded fixture.
        with socket.socket() as occupied:
            occupied.bind(('127.0.0.1', 0))
            occupied.listen()
            with (root / 'private-bind-failure.log').open('wb') as log:
                rejected = subprocess.Popen([str(binary), '--quiet', '--no-logfile'],
                    env={**env, 'BARKD_BIND_PORT':str(occupied.getsockname()[1])}, stdout=log, stderr=log)
                try:
                    assert rejected.wait(timeout=10) != 0, 'Daemon accepted an occupied listen port'
                finally:
                    if rejected.poll() is None:
                        rejected.kill(); rejected.wait(timeout=5)
            assert saved_text('barkd.url') == endpoint, 'Failed bind replaced discovery address'
            assert saved_text('auth_token') == initial_token, 'Failed bind replaced authentication'

        # A malformed existing credential must fail closed. Never silently
        # rotate it and strand the user's already-paired clients.
        damaged = 'synthetic-invalid-authentication'
        (data / 'auth_token').write_text(damaged)
        with (root / 'private-invalid-auth.log').open('wb') as log:
            rejected = subprocess.Popen([str(binary), '--quiet', '--no-logfile'],env=env,stdout=log,stderr=log)
            try:
                assert rejected.wait(timeout=10) != 0, 'Daemon accepted malformed saved authentication'
            finally:
                if rejected.poll() is None:
                    rejected.kill(); rejected.wait(timeout=5)
        assert saved_text('auth_token') == damaged, 'Malformed authentication was silently replaced'
        assert not (data / 'mnemonic').exists(), 'Failure path created wallet keys'
    print('PASS native daemon: isolated first launch, OS-assigned port discovery, authenticated shared UI, entropy rejection, origin boundary, private files, duplicate-instance rejection, crash recovery and fail-closed authentication; no wallet or payment created')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    if not binary.is_file():
        parser.error('--binary must be a built paperclip-walletd executable')
    check(binary)
