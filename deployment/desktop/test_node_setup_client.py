"""Native setup orchestration against disposable storage and synthetic nodes."""
import os
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'jam'))
from test_node_setup import NodeFixture
from node_setup_client import NodeSetupClient, choose_runtime
from managed_daemon import StartupError


class SetupClientTests(NodeFixture):
    def client(self):
        executable = os.environ.get('PAPERCLIP_NODE_CHECK_EXECUTABLE')
        self.runtime = (executable, None) if executable else (sys.executable,
            Path(os.environ.get('PAPERCLIP_NODE_CHECK_ENTRY', Path(__file__).resolve().parents[1] / 'jam/desktop-entry.py')))
        self.app = self.root / 'app'
        self.stopping = threading.Event()
        return NodeSetupClient(self.runtime, self.app, self.stopping)

    def test_deferral_never_creates_jars_or_wallet_storage(self):
        self.client(); events = []
        result = choose_runtime(self.runtime, self.app, None, self.stopping,
            lambda: {'action':'skip_jars'}, lambda *event: events.append(event))
        self.assertIsNone(result)
        self.assertEqual(events, [('setup', None)])
        self.assertFalse(self.app.exists())
        self.assertEqual(self.calls, [])

    def test_failed_verification_requires_explicit_retry_and_preserves_saved_connection(self):
        client = self.client(); port = self.node(); self.status = 401
        settings = {'endpoint':f'http://127.0.0.1:{port}', 'username':'fixture', 'password':'synthetic-secret'}
        with self.assertRaises(StartupError) as error: client.save(settings, lambda _: None)
        self.assertNotIn('synthetic-secret', str(error.exception))
        self.assertIn('rejected', str(error.exception))
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(client.status(), 'not_configured')
        self.assertEqual(len(self.calls), 1, 'Status must not retry verification')
        self.status = 200
        client.save(settings, lambda _: None)
        self.assertEqual(client.status(), 'saved')
        self.assertEqual(len(self.calls), 3)
        with self.assertRaises(StartupError): client.save(settings, lambda _: None)
        self.assertEqual(len(self.calls), 3, 'Saving again must not contact or replace the node')
        self.assertFalse((self.app / 'wallet').exists())
        self.assertFalse(list(self.app.rglob('*.jmdat')))

    def test_saved_state_does_not_prompt_or_contact_node(self):
        client = self.client(); port = self.node()
        client.save({'endpoint':f'http://127.0.0.1:{port}', 'username':'fixture', 'password':'synthetic-secret'}, lambda _: None)
        self.calls.clear()
        result = choose_runtime(self.runtime, self.app, None, self.stopping,
            lambda: self.fail('Saved connection prompted for replacement'),
            lambda *_: self.fail('Saved connection emitted initial setup'))
        self.assertEqual(result, self.runtime)
        self.assertEqual(self.calls, [])

    def test_cancelled_helper_is_reaped_and_does_not_save(self):
        client = self.client(); self.stopping.set()
        with self.assertRaises(StartupError): client.call('--node-status')
        self.assertFalse(self.app.exists())

    def test_cancel_during_node_request_does_not_save_or_automatically_retry(self):
        client = self.client(); port = self.node(); self.delay = 2
        settings = {'endpoint':f'http://127.0.0.1:{port}', 'username':'fixture', 'password':'synthetic-secret'}
        errors = []
        def verify():
            try: client.save(settings, lambda _: None)
            except StartupError as error: errors.append(str(error))
        worker = threading.Thread(target=verify); worker.start()
        try:
            deadline = time.monotonic()+10
            while not self.calls and worker.is_alive() and time.monotonic()<deadline: time.sleep(.01)
            self.assertEqual(len(self.calls),1)
        finally:
            self.stopping.set(); worker.join(timeout=5)
        self.assertFalse(worker.is_alive())
        self.assertEqual(len(errors),1)
        self.assertNotIn('synthetic-secret',errors[0])
        self.assertEqual(len(self.calls),1)
        self.assertFalse((self.app/'jars/node-connection.json').exists())
        self.stopping.clear()
        self.assertEqual(client.status(),'not_configured')
        self.assertEqual(len(self.calls),1)

    def test_explicit_retry_is_required_after_a_setup_error(self):
        client = self.client(); events = []; attempts = []
        requests = iter([{'action':'configure_jars','settings':{'tor':False}}, {'action':'skip_jars'}])
        def save(settings, progress):
            attempts.append(settings)
            raise StartupError('Check the node address.')
        with patch.object(NodeSetupClient, 'save', side_effect=save):
            result = choose_runtime(self.runtime, self.app, None, self.stopping,
                lambda: next(requests), lambda *event: events.append(event))
        self.assertIsNone(result)
        self.assertEqual(len(attempts), 1)
        self.assertEqual(events, [('setup',None), ('setup_error','Check the node address.')])

    def test_tor_bootstrap_cancellation_closes_child_without_node_request(self):
        client = self.client(); client.tor_binary = '/synthetic/tor'
        with patch('node_setup_client.ManagedTor') as tor:
            tor.return_value.start.return_value = {'socks_port':12345}
            tor.return_value.bootstrap_progress.return_value = 25
            def progress(text):
                if '25%' in text: self.stopping.set()
            with self.assertRaises(StartupError): client.save({'tor':True}, progress)
            tor.return_value.close.assert_called_once()
        self.assertEqual(self.calls, [])
        self.assertFalse((self.app / 'jars').exists())

    def test_guided_bridge_verifies_then_starts_saved_node_without_replay(self):
        binary = os.environ.get('PAPERCLIP_TEST_WALLET_BINARY')
        if not binary: self.skipTest('Supply the native wallet binary for combined setup acceptance')
        self.client(); port = self.node(); self.status = 401
        helper = os.environ.get('PAPERCLIP_TEST_DESKTOP_HELPER')
        command = [helper] if helper else [sys.executable, '-I', '-B', str(Path(__file__).with_name('launcher_entry.py'))]
        command += ['--binary',binary,'--root',str(self.app),'--guided-setup']
        command += ['--jam-executable',str(self.runtime[0])] if self.runtime[1] is None else ['--jam-python',str(self.runtime[0]),'--jam-entry',str(self.runtime[1])]
        process = subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
        events = queue.Queue()
        def read():
            for line in process.stdout: events.put(json.loads(line))
        reader = threading.Thread(target=read,daemon=True); reader.start()
        def event():
            value = events.get(timeout=15)
            self.assertNotIn('synthetic-secret',json.dumps(value))
            return value
        def send(value):
            process.stdin.write(json.dumps(value).encode()+b'\n');process.stdin.flush()
        try:
            self.assertEqual(event()['event'],'setup')
            request = {'action':'configure_jars','settings':{'endpoint':f'http://127.0.0.1:{port}',
                'username':'fixture','password':'synthetic-secret'}}
            send(request)
            self.assertEqual(event()['event'],'setup_progress')
            self.assertEqual(event()['event'],'setup_error')
            self.assertFalse((self.app/'wallet').exists())
            self.assertEqual(len(self.calls),1)
            self.status = 200
            send(request)
            self.assertEqual(event()['event'],'setup_progress')
            self.assertEqual(event()['event'],'setup_complete')
            self.assertEqual(event()['event'],'ready')
            # One failed check, two successful preflight calls, two startup calls.
            self.assertEqual(len(self.calls),5)
            self.assertFalse(list(self.app.rglob('*.jmdat')))
            self.assertFalse((self.app/'wallet/mnemonic').exists())
            send({'action':'quit'})
            self.assertEqual(event()['event'],'stopped')
            self.assertEqual(process.wait(timeout=10),0)
        finally:
            process.stdin.close()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill();process.wait(timeout=5)
            reader.join(timeout=2);process.stdout.close()


if __name__ == '__main__': unittest.main()
