"""Reviewed node replacement on disposable state and synthetic RPC only."""
import importlib.util
import io
import json
import os
import subprocess
import unittest
from unittest.mock import patch

from paperclip_jam import node_store
from paperclip_jam.node_setup import NodeSetupError
from test_node_setup import NodeFixture
import test_node_store as store_fixture


class ReplacementTests(NodeFixture):
    private_root = store_fixture.StoreTests.private_root
    write = store_fixture.StoreTests.write
    stored = store_fixture.StoreTests.stored
    configure = store_fixture.StoreTests.configure
    command = store_fixture.StoreTests.command

    def initial(self):
        root = self.private_root()
        port = self.node()
        identity = self.configure(root, port)['connection_id']
        self.calls.clear()
        return root, port, identity

    def replace(self, root, port, identity, **override):
        payload = {'settings': {'endpoint': f'http://127.0.0.1:{port}',
            'username': 'fixture', 'password': 'synthetic-new-secret'},
            'expected_connection_id': identity, 'confirmed': True}
        payload.update(override)
        result = subprocess.run(self.command() + ['--replace-node', '--data-dir', str(root)],
            input=json.dumps(payload).encode(), capture_output=True, timeout=25)
        self.assertEqual(result.stderr, b'')
        self.assertNotIn(b'synthetic-new-secret', result.stdout)
        self.assertNotIn(str(root).encode(), result.stdout)
        value = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0 if value['ready'] else 2)
        return value

    def test_success_preserves_wallet_journals_and_invalidates_old_review(self):
        root, port, identity = self.initial()
        sentinels = ['existing.jmdat', 'config.toml', 'recovery.sqlite']
        for name in sentinels: self.write(root / name, b'preserve-existing-wallet-state')
        result = self.replace(root, port, identity)
        self.assertTrue(result['saved']); self.assertFalse(result['active'])
        self.assertNotEqual(result['connection_id'], identity)
        saved = node_store.load(root)
        self.assertEqual(saved.connection_id, result['connection_id'])
        self.assertEqual(saved.settings.password, 'synthetic-new-secret')
        for name in sentinels: self.assertEqual((root / name).read_bytes(), b'preserve-existing-wallet-state')
        before = self.stored(root); self.calls.clear()
        self.assertEqual(self.replace(root, port, identity)['code'], 'stale_review')
        self.assertEqual(self.stored(root), before)
        self.assertEqual(self.calls, [])

    def test_explicit_boolean_confirmation_and_current_identity_precede_network(self):
        root, port, identity = self.initial(); before = self.stored(root)
        for value in (False, 1, 'true', None):
            self.assertEqual(self.replace(root, port, identity, confirmed=value)['code'], 'review_required')
        self.assertEqual(self.replace(root, port, 'f'*32)['code'], 'stale_review')
        self.assertEqual(self.replace(root, port, '')['code'], 'review_required')
        self.assertEqual(self.calls, [])
        self.assertEqual(self.stored(root), before)

    def test_failed_verification_preserves_old_record_without_retry(self):
        root, port, identity = self.initial(); before = self.stored(root); self.status = 401
        self.assertEqual(self.replace(root, port, identity)['code'], 'authentication')
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.stored(root), before)
        self.status = 200
        self.assertTrue(self.replace(root, port, identity)['saved'])
        self.assertEqual(len(self.calls), 3)

    def test_missing_and_legacy_state_are_not_implicitly_configured(self):
        port = self.node(); root = self.root / 'absent'
        self.assertEqual(self.replace(root, port, 'f'*32)['code'], 'unsafe_storage')
        self.assertFalse(root.exists())
        root = self.private_root()
        self.write(root / 'config.toml', b'preserve-legacy-settings')
        self.assertEqual(self.replace(root, port, 'f'*32)['code'], 'stale_review')
        self.assertEqual((root / 'config.toml').read_bytes(), b'preserve-legacy-settings')
        self.assertFalse((root / node_store.NAME).exists())
        self.assertEqual(self.calls, [])

    def test_running_service_lock_prevents_network_and_replacement(self):
        root, port, identity = self.initial(); before = self.stored(root)
        spec = importlib.util.spec_from_file_location('replace_entry_fixture', store_fixture.ENTRY)
        entry = importlib.util.module_from_spec(spec); spec.loader.exec_module(entry)
        with entry.entry_lock(root):
            self.assertEqual(self.replace(root, port, identity)['code'], 'setup_in_use')
        self.assertEqual(self.stored(root), before); self.assertEqual(self.calls, [])

    def test_damaged_record_cannot_be_replaced(self):
        root, port, identity = self.initial()
        self.write(root / node_store.NAME, b'{"version":')
        self.assertEqual(self.replace(root, port, identity)['code'], 'storage_failure')
        self.assertEqual(self.stored(root), b'{"version":'); self.assertEqual(self.calls, [])

    def test_record_changed_during_verification_is_not_overwritten(self):
        root, port, identity = self.initial()
        settings = self.settings(f'http://127.0.0.1:{port}')
        async def change_while_verifying(*_args):
            node_store.replace_verified(root, settings, identity)
            return {'ready': True}
        payload = {'expected_connection_id':identity, 'confirmed':True,
            'settings':{'endpoint':settings.endpoint,'username':'fixture','password':'synthetic-new-secret'}}
        output = io.StringIO()
        with patch.object(node_store, 'verify', side_effect=change_while_verifying):
            result = node_store.replace_pipe(root, io.BytesIO(json.dumps(payload).encode()), output)
        self.assertEqual(result, 2)
        self.assertEqual(json.loads(output.getvalue())['code'], 'stale_review')
        self.assertEqual(node_store.load(root).settings.password, 'synthetic-secret')
        self.assertFalse(list(root.glob('*.tmp')))
        self.assertEqual(self.calls, [])

    def test_linked_record_is_rejected_before_node_contact(self):
        root, port, identity = self.initial(); before = self.stored(root)
        os.link(root / node_store.NAME, root / 'hardlink')
        self.assertEqual(self.replace(root, port, identity)['code'], 'unsafe_storage')
        self.assertEqual((root / 'hardlink').read_bytes(), before); self.assertEqual(self.calls, [])

    def flush_failure(self, at):
        root, port, identity = self.initial(); before = self.stored(root)
        target, name = (node_store.native.win32file, 'FlushFileBuffers') if os.name == 'nt' else (node_store.os, 'fsync')
        original = getattr(target, name); count = 0
        def flush(*args):
            nonlocal count
            count += 1
            if count == at: raise OSError('Synthetic flush failure')
            return original(*args)
        with patch.object(target, name, side_effect=flush):
            with self.assertRaises(NodeSetupError) as error:
                node_store.replace_verified(root, self.settings(f'http://127.0.0.1:{port}'), identity)
        self.assertEqual(error.exception.code, 'storage_failure')
        self.assertFalse(list(root.glob('*.tmp')))
        if at == 1:
            self.assertEqual(self.stored(root), before)
        else:
            self.assertNotEqual(node_store.load(root).connection_id, identity)
            with self.assertRaises(NodeSetupError) as stale: node_store.require_current(root, identity)
            self.assertEqual(stale.exception.code, 'stale_review')

    def test_flush_failure_before_rename_preserves_old_connection(self): self.flush_failure(1)

    def test_flush_failure_after_rename_requires_new_review_without_rollback(self): self.flush_failure(2)


if __name__ == '__main__': unittest.main()
