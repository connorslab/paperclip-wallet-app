#!/usr/bin/env python3
"""Current Rust signatures against an owned, offline Knots regtest node.

No existing node, wallet or credentials are used. All coins are disposable.
Run through `just int-xbt-consensus /absolute/path/to/verified/bitcoind`.
"""
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener, ProxyHandler


def main(binary, fixture):
    binary, fixture = Path(binary).resolve(strict=True), Path(fixture).resolve(strict=True)
    http = build_opener(ProxyHandler({}))
    env = {key: os.environ[key] for key in ('PATH', 'HOME', 'TMPDIR', 'SYSTEMROOT') if key in os.environ}

    def generate(request):
        result = subprocess.run([str(fixture)], input=json.dumps(request).encode(),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=15)
        if result.returncode:
            raise RuntimeError('Rust fixture generation failed; no node submission')
        return json.loads(result.stdout)

    with tempfile.TemporaryDirectory(prefix='paperclip-xbt-consensus-') as temporary:
        root = Path(temporary)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        process = None
        cookie = root / 'regtest' / '.cookie'

        def rpc(method, *params):
            # Authentication comes only from the fresh, private owned datadir.
            headers = {'Authorization': 'Basic ' + base64.b64encode(cookie.read_bytes().strip()).decode(),
                       'Content-Type': 'application/json'}
            request = Request(f'http://127.0.0.1:{port}/',
                              json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode(), headers)
            try:
                with http.open(request, timeout=15) as response:
                    result = json.load(response)
            except HTTPError as error:
                raise RuntimeError(f'Owned regtest RPC {method} failed with HTTP {error.code}') from None
            if result.get('error'):
                raise RuntimeError(f'Owned regtest RPC {method} failed')
            return result['result']

        def stop():
            if process is not None and process.poll() is None:
                try:
                    rpc('stop')
                    process.wait(timeout=20)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)

        with (root / 'node.log').open('wb') as log:
            def start(extra=()):
                nonlocal process
                process = subprocess.Popen([str(binary), '-regtest', '-server', '-listen=0', '-connect=0',
                    '-discover=0', '-dnsseed=0', '-disablewallet', '-rpcbind=127.0.0.1',
                    '-rpcallowip=127.0.0.1', f'-rpcport={port}', f'-datadir={root}', *extra],
                    stdout=log, stderr=log, env=env)
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError('Owned Knots exited before readiness')
                    try:
                        info = rpc('getblockchaininfo')
                        assert info['chain'] == 'regtest'
                        return
                    except (FileNotFoundError, URLError, TimeoutError, RuntimeError):
                        time.sleep(0.1)
                raise RuntimeError('Owned Knots readiness timed out')

            try:
                start()
                cases = []
                for kind in ('taproot', 'segwit'):
                    public = generate({'kind': kind})
                    block = rpc('generatetoaddress', 1, public['address'])[0]
                    coinbase = rpc('getblock', block, 2)['tx'][0]
                    vout = next(i for i, output in enumerate(coinbase['vout']) if output['scriptPubKey']['hex'] == public['script'])
                    cases.append(generate({'kind': kind, 'funding_tx': coinbase['hex'], 'vout': vout}))
                rpc('generatetoaddress', 101, public['address'])
                for transactions in cases:
                    before = rpc('testmempoolaccept', [transactions['valid']])[0]
                    assert before['allowed'] is False and 'missing' not in before.get('reject-reason', '')
                activation = rpc('getblockcount') + 1
                stop()
                settings = [f'-testactivationheight=blake2b@{activation}',
                            '-blake2b_headline=Paperclip disposable consensus test',
                            f'-rdtsexpiry={int(time.time()) + 365 * 86400}']
                start(settings)
                rpc('generatetoaddress', 1, public['address'])
                assert rpc('getdeploymentinfo')['blake2b']['active']
                txids = []
                for transactions in cases:
                    assert rpc('testmempoolaccept', [transactions['valid']])[0]['allowed']
                    for name in ('changed_output', 'legacy_digest'):
                        rejected = rpc('testmempoolaccept', [transactions[name]])[0]
                        assert rejected['allowed'] is False and 'missing' not in rejected.get('reject-reason', '')
                    txid = rpc('sendrawtransaction', transactions['valid'])
                    assert txid == transactions['txid']
                    txids.append(txid)
                mined = rpc('generatetoaddress', 1, public['address'])[0]
                assert set(txids).issubset(rpc('getblock', mined)['tx'])
                rpc('invalidateblock', mined)
                assert set(txids).issubset(rpc('getrawmempool'))
                stop()
                start(settings)
                deadline = time.monotonic() + 15
                while not set(txids).issubset(rpc('getrawmempool')):
                    if time.monotonic() > deadline:
                        raise RuntimeError('Owned node did not restore its mempool')
                    time.sleep(0.1)
                # Do not regenerate the exact header explicitly invalidated above.
                rpc('setmocktime', int(time.time()) + 60)
                mined = rpc('generatetoaddress', 1, public['address'])[0]
                assert set(txids).issubset(rpc('getblock', mined)['tx'])
                print('PASS: Taproot and SegWit pre-activation rejection, active unified acceptance, tamper/legacy rejection, mining, reorg and restart recovery; synthetic regtest only')
            finally:
                stop()


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Pass the verified Knots binary and compiled Rust fixture paths')
    main(*sys.argv[1:])
