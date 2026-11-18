"""Credential-free saved-state inspection; no node calls or wallet mutation."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from paperclip_jam import node_setup, node_store

if os.name == 'nt':
    from windows import private_storage as native

ENTRY = Path(__file__).with_name('desktop-entry.py').resolve()


class NodeStatus(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / 'jars'

    def directory(self):
        if os.name == 'nt': native.private_directory(self.root)
        else: self.root.mkdir(mode=0o700)

    def write(self, name, value):
        path = self.root / name
        if os.name == 'nt': native.create_private_file(path,value)
        else: path.write_bytes(value); path.chmod(0o600)

    def read(self):
        executable = os.environ.get('PAPERCLIP_NODE_CHECK_EXECUTABLE')
        command = [executable] if executable else [sys.executable,'-I',str(ENTRY)]
        result = subprocess.run(command+['--node-status','--data-dir',str(self.root)],
            stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5)
        self.assertEqual(result.stderr,b'')
        self.assertNotIn(b'synthetic-secret',result.stdout)
        self.assertNotIn(b'private-user',result.stdout)
        self.assertNotIn(b'127.0.0.1:1',result.stdout)
        value = json.loads(result.stdout)
        self.assertEqual(result.returncode,2 if value['state']=='needs_attention' else 0)
        self.assertEqual(value['live_connection'],'not_checked')
        return value

    def test_missing_and_empty_roots_are_not_created_or_locked(self):
        self.assertEqual(self.read()['state'],'not_configured')
        self.assertFalse(self.root.exists())
        self.directory()
        self.assertTrue(self.read()['can_configure'])
        self.assertEqual(list(self.root.iterdir()),[])

    def test_saved_status_does_not_verify_node_or_disclose_credentials(self):
        self.directory()
        settings=node_setup.NodeSettings.parse({'endpoint':'http://127.0.0.1:1',
            'username':'private-user','password':'synthetic-secret'})
        saved=node_store.save_initial(self.root,settings)
        before=(self.root/node_store.NAME).read_bytes()
        status=self.read()
        self.assertEqual(status,{'state':'saved','can_configure':False,
            'connection_id':saved['connection_id'],'transport':'loopback','live_connection':'not_checked'})
        self.assertEqual((self.root/node_store.NAME).read_bytes(),before)
        self.assertEqual(set(p.name for p in self.root.iterdir()),{node_store.NAME})

    def test_existing_wallet_configuration_is_not_offered_initial_setup(self):
        self.directory(); self.write('config.toml',b'preserve-existing-settings')
        self.assertEqual(self.read(),{'state':'existing_wallet','can_configure':False,'live_connection':'not_checked'})
        self.assertEqual((self.root/'config.toml').read_bytes(),b'preserve-existing-settings')
        self.assertFalse((self.root/node_store.NAME).exists())

    def test_damaged_record_requires_attention_and_is_not_replaced(self):
        self.directory(); self.write(node_store.NAME,b'{"password":"synthetic-secret"')
        before=(self.root/node_store.NAME).read_bytes()
        value=self.read()
        self.assertEqual(value['state'],'needs_attention')
        self.assertFalse(value['can_configure'])
        self.assertEqual(value['code'],'storage_failure')
        self.assertEqual((self.root/node_store.NAME).read_bytes(),before)

    def test_inspection_does_not_compete_with_the_running_service(self):
        self.directory()
        node_store.save_initial(self.root,node_setup.NodeSettings.parse({'endpoint':'https://node.invalid',
            'username':'private-user','password':'synthetic-secret'}))
        spec=importlib.util.spec_from_file_location('entry_status_fixture',ENTRY)
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        with module.entry_lock(self.root):
            value=self.read()
        self.assertEqual(value['state'],'saved');self.assertEqual(value['transport'],'https')

    def test_linked_record_is_not_treated_as_a_missing_connection(self):
        self.directory()
        node_store.save_initial(self.root,node_setup.NodeSettings.parse({'endpoint':'http://127.0.0.1:1',
            'username':'private-user','password':'synthetic-secret'}))
        os.link(self.root/node_store.NAME,self.root/'alias')
        value=self.read()
        self.assertEqual(value['state'],'needs_attention')
        self.assertFalse(value['can_configure'])
        self.assertEqual(value['code'],'unsafe_storage')


if __name__=='__main__': unittest.main()
