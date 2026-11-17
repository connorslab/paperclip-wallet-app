"""Native certificate handoff uses disposable identities, never wallet material."""
import datetime
import os
from pathlib import Path
import tempfile
import unittest

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from paperclip_jam.hosting import export_certificate

if os.name == 'nt':
    from windows.private_storage import private_directory, atomic_write_private, read_private_file


class CertificateHandoff(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'ssl' / 'cert.pem'
        self.target = self.root / 'handoff' / 'cert.pem'
        for directory in (self.source.parent, self.target.parent):
            if os.name == 'nt':
                private_directory(directory)
            else:
                directory.mkdir(mode=0o700)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'unfunded-fixture')])
        key = ec.generate_private_key(ec.SECP256R1())
        now = datetime.datetime.now(datetime.timezone.utc)
        certificate = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(1).not_valid_before(now)
            .not_valid_after(now + datetime.timedelta(days=1)).sign(key, hashes.SHA256()))
        self.certificate = certificate.public_bytes(serialization.Encoding.PEM)
        self.write(self.source, self.certificate)

    def write(self, path, data):
        if os.name == 'nt':
            atomic_write_private(path, data)
        else:
            path.write_bytes(data)
            path.chmod(0o600)

    def read(self, path):
        if os.name == 'nt':
            with read_private_file(path) as reader:
                return reader.read()
        return path.read_bytes()

    def test_handoff_replaces_only_the_public_certificate(self):
        self.write(self.target, b'old-public-fixture')
        export_certificate(self.root, self.target)
        self.assertEqual(self.read(self.target), self.certificate)
        self.assertNotIn(b'PRIVATE KEY', self.read(self.target))
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])

    def test_private_material_and_malformed_or_oversized_input_preserve_handoff(self):
        self.write(self.target, self.certificate)
        for invalid in (b'not a certificate', self.certificate + b'PRIVATE KEY', b'x' * 16385):
            self.write(self.source, invalid)
            with self.assertRaises(ValueError):
                export_certificate(self.root, self.target)
            self.assertEqual(self.read(self.target), self.certificate)

    @unittest.skipUnless(os.name == 'nt', 'Native Windows ownership check')
    def test_hard_linked_certificate_is_rejected_before_handoff(self):
        os.link(self.source, self.root / 'alias.pem')
        with self.assertRaises(ValueError):
            export_certificate(self.root, self.target)
        self.assertFalse(self.target.exists())


if __name__ == '__main__':
    unittest.main()
