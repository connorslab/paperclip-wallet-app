"""Give newly generated Windows TLS certificates explicit private ownership."""
import argparse
import hashlib
from pathlib import Path

EXPECTED = '3c6dea8cb4e9afbb951617e43f37d2c12d7d1b5b071781d35c7e819d03ade040'


def patch(path):
    original = path.read_bytes()
    if hashlib.sha256(original).hexdigest() != EXPECTED:
        raise ValueError('Jam TLS source does not match the reviewed pinned runtime')
    source = original.decode().replace('from pathlib import Path', 'import os\nfrom pathlib import Path', 1)
    source = source.replace('    cert_file.write_bytes(cert.public_bytes(serialization.Encoding.PEM))',
        '    if os.name == "nt":\n'
        '        atomic_write_private(cert_file, cert.public_bytes(serialization.Encoding.PEM))\n'
        '    else:\n'
        '        cert_file.write_bytes(cert.public_bytes(serialization.Encoding.PEM))', 1)
    compile(source, str(path), 'exec')
    with path.open('w', encoding='utf-8', newline='\n') as output:
        output.write(source)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    patch(parser.parse_args().source)
