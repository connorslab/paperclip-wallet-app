import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

from jmwalletd.cli import _generate_self_signed_cert

from paperclip_jam.hosting import export_certificate


class HostingTest(unittest.TestCase):
    def test_handoff_exports_only_public_certificate_and_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            private, public = root / 'private', root / 'public'
            private.mkdir()
            public.mkdir()
            _generate_self_signed_cert(private / 'ssl')
            target = public / 'cert.pem'
            export_certificate(private, target)
            self.assertEqual(target.read_bytes(), (private / 'ssl' / 'cert.pem').read_bytes())
            self.assertEqual([path.name for path in public.iterdir()], ['cert.pem'])
            self.assertNotIn(b'PRIVATE KEY', target.read_bytes())
            self.assertEqual(target.stat().st_mode & 0o777, 0o644)
            target.unlink()
            target.symlink_to(private / 'ssl' / 'key.pem')
            with self.assertRaises(ValueError):
                export_certificate(private, target)
            self.assertTrue((private / 'ssl' / 'key.pem').exists())

    def test_filter_only_inherits_selected_node_credentials(self):
        spec = importlib.util.spec_from_file_location('rpc_entry', Path(__file__).with_name('rpc-entry.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        values = {'PATH': '/synthetic', 'APP_PASSWORD': 'synthetic-wallet-secret',
            'NODE_BITCOIN_IP': 'node', 'NODE_BITCOIN_PORT': '18443',
            'NODE_BITCOIN_USER': 'fixture', 'NODE_BITCOIN_PASS': 'synthetic-node-secret',
            'NODE_KNOTS_BLAKE2B_PASS': 'synthetic-unselected-secret', 'JM_RPC_FILTER_MODE': 'record'}
        env = module.environment(values)
        self.assertEqual(env['JM_RPC_FILTER_NODE_URL'], 'http://node:18443')
        self.assertEqual(env['JM_RPC_FILTER_MODE'], 'enforce')
        self.assertNotIn('APP_PASSWORD', env)
        self.assertNotIn('synthetic-unselected-secret', env.values())
        for field, value in [('NODE_BITCOIN_IP', 'user@node'), ('NODE_BITCOIN_IP', 'node/path'),
                ('NODE_BITCOIN_PORT', '0'), ('NODE_BITCOIN_PORT', '65536'), ('NODE_BITCOIN_PASS', '')]:
            with self.assertRaises(ValueError):
                module.environment({**values, field: value})


if __name__ == '__main__':
    unittest.main()
