"""Create-once node setup with private disposable files and synthetic RPC."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import unittest
from unittest.mock import patch

from paperclip_jam import node_setup, node_store
from test_node_setup import NodeFixture

if os.name == 'nt':
    from windows import private_storage as native

ENTRY = Path(__file__).with_name('desktop-entry.py').resolve()


class StoreTests(NodeFixture):
    def private_root(self, name='settings'):
        path = self.root / name
        if os.name == 'nt': native.private_directory(path)
        else: path.mkdir(mode=0o700)
        return path

    def write(self, path, value):
        if os.name == 'nt': native.atomic_write_private(path, value)
        else:
            path.write_bytes(value); path.chmod(0o600)

    def stored(self, root):
        if os.name == 'nt':
            with native.read_private_file(root / node_store.NAME) as stream: return stream.read()
        return (root / node_store.NAME).read_bytes()

    def command(self):
        executable = os.environ.get('PAPERCLIP_NODE_CHECK_EXECUTABLE')
        return [executable] if executable else [sys.executable, '-I', str(ENTRY)]

    def configure(self, root, port):
        payload = {'endpoint':f'http://127.0.0.1:{port}', 'username':'fixture', 'password':'synthetic-secret'}
        result = subprocess.run(self.command() + ['--configure-node', '--data-dir', str(root)],
            input=json.dumps(payload).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25)
        self.assertEqual(result.stderr, b'')
        self.assertNotIn(b'synthetic-secret', result.stdout)
        value = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0 if value['ready'] else 2)
        return value

    def test_first_save_is_private_versioned_and_not_active(self):
        root = self.private_root(); port = self.node()
        result = self.configure(root, port)
        self.assertTrue(result['saved']); self.assertFalse(result['active'])
        saved = node_store.load(root)
        self.assertEqual(saved.connection_id, result['connection_id'])
        self.assertEqual(saved.settings.password, 'synthetic-secret')
        self.assertNotIn('synthetic-secret', repr(saved))
        self.assertNotIn('fixture', repr(saved.settings))
        self.assertEqual(set(json.loads(self.stored(root))), {'version', 'connection_id', 'settings'})
        self.assertEqual(set(p.name for p in root.iterdir()), {'desktop.lock', node_store.NAME})
        if os.name != 'nt': self.assertEqual(stat.S_IMODE((root / node_store.NAME).stat().st_mode), 0o600)
        self.assertEqual([call[0]['method'] for call in self.calls], ['getblockchaininfo','getblockheader'])

    def test_second_save_preserves_settings_without_contacting_another_node(self):
        root = self.private_root(); port = self.node()
        self.configure(root, port); before = self.stored(root); self.calls.clear()
        result = self.configure(root, port)
        self.assertEqual(result['code'], 'existing_setup')
        self.assertEqual(self.stored(root), before); self.assertEqual(self.calls, [])

    def test_pending_setup_cannot_fall_back_to_the_default_node(self):
        root = self.private_root(); port = self.node()
        self.configure(root, port); before = self.stored(root); self.calls.clear()
        result = subprocess.run(self.command() + ['--data-dir', str(root)], input=b'',
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b'')
        self.assertNotIn(b'synthetic-secret', result.stderr)
        self.assertEqual(self.stored(root), before); self.assertEqual(self.calls, [])
        self.assertEqual(set(p.name for p in root.iterdir()), {'desktop.lock', node_store.NAME})

    def test_failed_verification_saves_no_credentials_and_allows_corrected_attempt(self):
        root = self.private_root(); port = self.node(); self.status = 401
        self.assertEqual(self.configure(root, port)['code'], 'authentication')
        self.assertFalse((root / node_store.NAME).exists())
        self.assertEqual(set(p.name for p in root.iterdir()), {'desktop.lock'})
        self.status = 200
        self.assertTrue(self.configure(root, port)['saved'])

    def test_legacy_configuration_wallets_and_recovery_journals_are_never_replaced(self):
        port = self.node()
        for index, name in enumerate(['config.toml','wallets/fixture.jmdat','paperclip/payments.sqlite','unknown.jmdat']):
            root = self.private_root(f'legacy{index}')
            target = root / name
            if target.parent != root:
                if os.name == 'nt': native.private_directory(target.parent)
                else: target.parent.mkdir(mode=0o700)
            self.write(target, b'preserve-existing-fixture')
            self.assertEqual(self.configure(root, port)['code'], 'existing_setup')
            self.assertEqual(target.read_bytes(), b'preserve-existing-fixture')
            self.assertFalse((root / node_store.NAME).exists())
        self.assertEqual(self.calls, [])

    def test_running_service_lock_blocks_setup_without_network_or_writes(self):
        root = self.private_root(); port = self.node()
        spec = importlib.util.spec_from_file_location('entry_fixture', ENTRY)
        entry = importlib.util.module_from_spec(spec); spec.loader.exec_module(entry)
        with entry.entry_lock(root):
            self.assertEqual(self.configure(root, port)['code'], 'setup_in_use')
        self.assertFalse((root / node_store.NAME).exists()); self.assertEqual(self.calls, [])

    def test_partial_unknown_and_oversized_records_are_not_accepted_or_overwritten(self):
        settings = self.settings('http://127.0.0.1:8332')
        for index, data in enumerate([b'{"version":', b'{}', b'x'*(node_setup.MAX_INPUT+1),
                b'{"version":true,"connection_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","settings":{}}']):
            root = self.private_root(f'invalid{index}'); target = root / node_store.NAME
            self.write(target, data)
            with self.assertRaises(node_setup.NodeSetupError): node_store.load(root)
            with self.assertRaises(node_setup.NodeSetupError): node_store.save_initial(root, settings)
            self.assertEqual(self.stored(root), data)

    def test_storage_failure_is_reported_and_partial_state_is_not_retried(self):
        root = self.private_root(); settings = self.settings('http://127.0.0.1:8332')
        if os.name == 'nt':
            target, name = native, '_write_private_handle'
        else:
            target, name = node_store.os, 'fsync'
        with patch.object(target, name, side_effect=OSError('synthetic storage failure')):
            with self.assertRaises(node_setup.NodeSetupError) as error: node_store.save_initial(root, settings)
        self.assertEqual(error.exception.code, 'storage_failure')
        self.assertTrue((root / node_store.NAME).exists())
        before = self.stored(root)
        with self.assertRaises(node_setup.NodeSetupError): node_store.save_initial(root, settings)
        self.assertEqual(self.stored(root), before)

    def test_missing_load_does_not_create_storage(self):
        root = self.root / 'absent'
        self.assertIsNone(node_store.load(root)); self.assertFalse(root.exists())
        root = self.private_root()
        self.assertIsNone(node_store.load(root)); self.assertEqual(list(root.iterdir()), [])

    def test_competing_file_creation_is_never_overwritten(self):
        root = self.private_root()
        original = node_store.admit
        def compete(path):
            original(path)
            self.write(path / node_store.NAME, b'preserve-racing-fixture')
        with patch.object(node_store, 'admit', side_effect=compete):
            with self.assertRaises(node_setup.NodeSetupError) as error:
                node_store.save_initial(root, self.settings('http://127.0.0.1:8332'))
        self.assertEqual(error.exception.code, 'storage_failure')
        self.assertEqual(self.stored(root), b'preserve-racing-fixture')

    def test_hard_linked_record_is_rejected(self):
        root = self.private_root()
        node_store.save_initial(root, self.settings('http://127.0.0.1:8332'))
        os.link(root / node_store.NAME, root / 'alias')
        with self.assertRaises(node_setup.NodeSetupError): node_store.load(root)

    @unittest.skipIf(os.name == 'nt', 'Windows ACL/alias rejection is covered by native storage tests')
    def test_shared_files_directories_symlinks_and_special_files_are_rejected(self):
        root = self.private_root()
        node_store.save_initial(root, self.settings('http://127.0.0.1:8332'))
        target = root / node_store.NAME
        target.chmod(0o644)
        with self.assertRaises(node_setup.NodeSetupError): node_store.load(root)
        target.chmod(0o600); root.chmod(0o755)
        with self.assertRaises(node_setup.NodeSetupError): node_store.load(root)
        root.chmod(0o700)
        alias = self.root / 'alias'; alias.symlink_to(root)
        with self.assertRaises(node_setup.NodeSetupError): node_store.load(alias)
        target.unlink(); target.symlink_to(self.root / 'unrelated')
        with self.assertRaises(node_setup.NodeSetupError): node_store.load(root)
        target.unlink(); os.mkfifo(target, mode=0o600)
        with self.assertRaises(node_setup.NodeSetupError): node_store.load(root)


if __name__ == '__main__': unittest.main()
