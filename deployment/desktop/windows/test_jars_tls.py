"""Exercise the actual patched TLS generator in the native Jars environment."""
from pathlib import Path
import ssl
import tempfile
import unittest

from loguru import logger
from jmwalletd.cli import _generate_self_signed_cert
from windows.private_storage import read_private_file


class NativeTLS(unittest.TestCase):
    def test_generator_creates_owned_files_and_a_valid_pair(self):
        logger.remove()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / 'ssl'
            _generate_self_signed_cert(root)
            for name in ['key.pem', 'cert.pem']:
                with read_private_file(root / name):
                    pass
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(root / 'cert.pem', root / 'key.pem')


if __name__ == '__main__':unittest.main()
