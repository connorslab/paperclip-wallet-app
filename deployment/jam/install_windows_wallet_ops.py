"""Patch only the reviewed upstream wallet-operation lock on Windows."""
import argparse
import hashlib
from pathlib import Path

EXPECTED = '0b62415498440cf9ba3e4f8b645f3d73a9d6456ef0120061181ccd7e3e82eaae'


def patch(path):
    original = path.read_bytes()
    if hashlib.sha256(original).hexdigest() != EXPECTED:
        raise ValueError('Jam wallet-operation source does not match the reviewed pinned runtime')
    # The POSIX reservation remains unchanged. Windows cannot import fcntl.
    source = original.decode().replace('import fcntl\nimport os\n', 'import os\nif os.name != "nt":\n    import fcntl\n')
    source += '\n\nif os.name == "nt":\n    from paperclip_jam.windows_wallet_ops import reserve_wallet_path as _reserve_wallet_path\n'
    compile(source, str(path), 'exec')
    with path.open('w', encoding='utf-8', newline='\n') as output:
        output.write(source)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    patch(parser.parse_args().source)
