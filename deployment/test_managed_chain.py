import importlib.util
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('managed', Path(__file__).with_name('managed-chain.py'))
managed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(managed)


class ManagedChainTests(unittest.TestCase):
    def test_private_arguments_do_not_expose_rpc_password_or_allow_short_history(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'backend.json').write_text(json.dumps({'network': 'main', 'rpc_url': 'http://node:8332'}))
            args = managed.adapter_args(root)
            self.assertEqual(args[args.index('--first-height') + 1], '961640')
            self.assertNotIn('--bind', args)
            self.assertIn(str(root / 'backend.cookie'), args)
            (root / 'backend.json').write_text(json.dumps({'network': 'regtest', 'rpc_url': 'http://node:18443'}))
            args = managed.adapter_args(root)
            self.assertIn('--regtest', args)
            self.assertEqual(args[args.index('--first-height') + 1], '0')

    def test_reject_credentials_in_url_and_invalid_network(self):
        base = {'network': 'main', 'rpc_url': 'http://node:8332', 'rpc_user': 'owner', 'rpc_password': 'test-password'}
        managed.validate(base)
        for update in ({'rpc_url': 'http://user:secret@node/'}, {'network': 'signet'}, {'rpc_user': 'owner:secret'}, {'rpc_url': 'file:///etc/passwd'}):
            with self.assertRaises(ValueError):
                managed.validate(dict(base, **update))


class ManagedProcessLifecycleTests(unittest.TestCase):
    """Real owned child processes; fake node, Tor and wallet never use the network."""

    def run_lifecycle(self, stop_wallet):
        with tempfile.TemporaryDirectory(prefix='paperclip-supervisor-') as temporary:
            root = Path(temporary)
            chain, library = root / 'chain', root / 'lib'
            chain.mkdir()
            library.mkdir()
            (chain / 'backend.json').write_text(json.dumps({'network': 'regtest', 'rpc_url': 'http://127.0.0.1:1'}))
            stub = '''import os, signal, sys, time
from pathlib import Path
root = Path(os.environ['PAPERCLIP_TEST_ROOT'])
name = Path(sys.argv[0]).stem
def stop(*_):
    (root / (name + '.stopped')).write_text('terminated')
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
marker = root / (name + '.pid')
marker.with_suffix('.tmp').write_text(str(os.getpid()))
os.replace(marker.with_suffix('.tmp'), marker)
while True:
    if name == 'entrypoint' and (root / 'exit-wallet').exists():
        raise SystemExit(7)
    time.sleep(.02)
'''
            for name in ('pruned_rpc.py', 'entrypoint.py', 'tor_stub.py'):
                (library / name).write_text(stub)
            runner = '''import importlib.util, os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import node_tor
spec = importlib.util.spec_from_file_location('managed', Path(sys.argv[1]) / 'managed-chain.py')
managed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(managed)
root = Path(os.environ['PAPERCLIP_TEST_ROOT'])
managed.ROOT, managed.LIB = root / 'chain', root / 'lib'
original_args = managed.adapter_args
managed.adapter_args = lambda: original_args(managed.ROOT, managed.LIB)
node_tor.arguments = lambda env: [sys.executable, str(managed.LIB / 'tor_stub.py')]
raise SystemExit(managed.supervise())
'''
            env = {key: os.environ[key] for key in ('PATH', 'HOME', 'TMPDIR') if key in os.environ}
            env.update(PAPERCLIP_TEST_ROOT=str(root), BARKD_DATADIR=str(root / 'wallet'))
            # Kill only this process group if an assertion fails; never leave a
            # test child running or touch an installed wallet service.
            with (root / 'private.log').open('wb') as log:
                process = subprocess.Popen([sys.executable, '-c', runner, str(Path(__file__).resolve().parent)],
                    env=env, stdout=log, stderr=log, start_new_session=True)
                try:
                    deadline = time.monotonic() + 10
                    names = ('pruned_rpc', 'entrypoint', 'tor_stub')
                    while not all((root / (name + '.pid')).exists() for name in names):
                        self.assertIsNone(process.poll(), 'Fixture supervisor exited before startup')
                        self.assertLess(time.monotonic(), deadline, 'Fixture children did not start')
                        time.sleep(.02)
                    pids = [int((root / (name + '.pid')).read_text()) for name in names]
                    if stop_wallet:
                        (root / 'exit-wallet').touch()
                    else:
                        process.send_signal(signal.SIGTERM)
                    self.assertEqual(process.wait(timeout=10), 7 if stop_wallet else 0)
                    for name, pid in zip(names, pids):
                        if not (stop_wallet and name == 'entrypoint'):
                            self.assertEqual((root / (name + '.stopped')).read_text(), 'terminated')
                        with self.assertRaises(ProcessLookupError):
                            os.kill(pid, 0)
                finally:
                    # The group remains distinct even if its leader has exited.
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=5)

    @unittest.skipUnless(os.name == 'posix', 'Packaged server supervisor uses POSIX signals')
    def test_shutdown_terminates_and_reaps_all_owned_services(self):
        self.run_lifecycle(stop_wallet=False)

    @unittest.skipUnless(os.name == 'posix', 'Packaged server supervisor uses POSIX signals')
    def test_wallet_exit_stops_helpers_and_preserves_failure_status(self):
        self.run_lifecycle(stop_wallet=True)
