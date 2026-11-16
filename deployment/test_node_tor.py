from pathlib import Path
import tempfile
import unittest
from node_tor import arguments


class NodeTorTests(unittest.TestCase):
    def test_local_only_proxy_and_private_persistent_directory(self):
        with tempfile.TemporaryDirectory() as folder:
            args = arguments({'BARKD_DATADIR': folder})
            self.assertEqual(args[args.index('--SocksPort') + 1], '127.0.0.1:9050')
            self.assertIn('reject *', args)
            self.assertEqual((Path(folder) / 'tor').stat().st_mode & 0o777, 0o700)
            self.assertNotIn('--ControlPort', args)

    def test_external_proxy_has_no_local_side_effects(self):
        self.assertIsNone(arguments({'BARKD_LIGHTNING_TOR_PROXY': 'socks5h://platform:9050', 'BARKD_DATADIR': '/not-created'}))

    def test_symlink_storage_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            Path(folder, 'tor').symlink_to('/tmp')
            with self.assertRaises(ValueError):
                arguments({'BARKD_DATADIR': folder})
