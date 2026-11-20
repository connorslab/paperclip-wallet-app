import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('packaging', Path(__file__).with_name('package.py'))
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class PackageTest(unittest.TestCase):
    def test_manifest_security_and_backup_contracts(self):
        with tempfile.TemporaryDirectory() as directory:
            # Synthetic reference used only for generator tests, never published.
            image = 'example.invalid/paperclip:test@sha256:' + 'a' * 64
            for platform in ('umbrel', 'startos'):
                out = Path(directory) / platform
                packaging.package(platform, image, out, jam_image=image if platform == 'umbrel' else None)
                if platform == 'umbrel':
                    cfg = json.loads((out / 'docker-compose.yml').read_text())
                    service = cfg['services']['wallet']
                    self.assertNotIn('ports', service)
                    self.assertNotIn('PROXY_AUTH_ADD', cfg['services']['app_proxy']['environment'])
                    self.assertNotIn('APP_SEED', service['environment'])
                    self.assertEqual(service['user'], '1000:1000')
                else:
                    cfg = json.loads((out / 'manifest.yaml').read_text())
                    for action in ('create', 'restore'):
                        self.assertEqual(cfg['backup'][action]['mounts']['main'], '/data')
                        self.assertEqual(cfg['backup'][action]['args'][-1], '/data')
                    self.assertEqual(cfg['dependencies'], {}, 'Do not mandate a BTC node package')
                with self.assertRaises(FileExistsError):
                    packaging.package(platform, image, out, jam_image=image if platform == 'umbrel' else None)

    def test_unpinned_image_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                packaging.package('umbrel', 'repo:latest', Path(directory) / 'new')

    def test_umbrel_cannot_silently_omit_its_jars_runtime(self):
        image = 'example.invalid/paperclip:test@sha256:' + 'a' * 64
        with tempfile.TemporaryDirectory() as directory:
            for jam in (None, 'example.invalid/jam:latest'):
                out = Path(directory) / 'incomplete'
                with self.assertRaises(ValueError):
                    packaging.package('umbrel', image, out, jam_image=jam)
                self.assertFalse(out.exists(), 'Reject incomplete packages before writing files')

    def test_bundled_jam_has_separate_data_filtered_rpc_and_verified_loopback_tls(self):
        image = 'example.invalid/paperclip:test@sha256:' + 'a' * 64
        jam = 'example.invalid/paperclip-jam:test@sha256:' + 'b' * 64
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / 'umbrel'
            packaging.package('umbrel', image, out, jam_image=jam)
            services = json.loads((out / 'docker-compose.yml').read_text())['services']
            wallet, companion, rpc = (services[name] for name in ('wallet', 'jam', 'jam-rpc'))
            self.assertEqual(companion['image'], jam)
            self.assertEqual(rpc['image'], jam)
            self.assertEqual(companion['environment']['JMWALLETD_HOST'], '127.0.0.1')
            self.assertNotIn('JMWALLETD_NO_TLS', companion['environment'])
            self.assertNotIn('network_mode', wallet)
            self.assertNotIn('jam', wallet.get('depends_on', []))
            self.assertEqual(companion['network_mode'], 'service:wallet')
            self.assertEqual(companion['depends_on'], ['wallet', 'jam-rpc'])
            self.assertEqual(wallet['environment']['BARKD_JARS_PAIRING_ONION'], '${APP_HIDDEN_SERVICE:-}')
            self.assertEqual(wallet['environment']['BARKD_JOINBLAKET_URL'], 'https://localhost:28183')
            self.assertIn('${APP_DATA_DIR}/jam-public:/run/paperclip-jam-public:ro', wallet['volumes'])
            self.assertFalse(any('/jam:' in volume or '/jam-rpc:' in volume for volume in wallet['volumes']))
            self.assertFalse(any('NODE_' in key for key in companion['environment']))
            for service in (wallet, companion, rpc):
                self.assertNotIn('ports', service)
                self.assertEqual(service['cap_drop'], ['ALL'])
                self.assertEqual(service['user'], '1000:1000')
            self.assertEqual(services['app_proxy']['environment']['APP_HOST'], 'paperclip-wallet_wallet_1')
            self.assertEqual(services['app_proxy']['environment']['PROXY_AUTH_WHITELIST'], '/api/v1/paired-jars/request')
            self.assertNotIn('PROXY_AUTH_ADD', services['app_proxy']['environment'])
            self.assertEqual(json.loads((out / 'umbrel-app.yml').read_text())['dependencies'], ['bitcoin'])
            for volume in ('data', 'jam', 'jam-rpc', 'jam-public'):
                self.assertTrue((out / volume).is_dir())


if __name__ == '__main__':
    unittest.main()
