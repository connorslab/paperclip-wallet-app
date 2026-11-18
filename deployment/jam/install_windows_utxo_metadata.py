"""Retain pinned CoinJoin input ownership with a native private sidecar lock."""
import argparse
import hashlib
from pathlib import Path

EXPECTED = 'a4d1656e3b70dc4dd14630182d82996f4dec38f4bd9ed97e692bef988ccbd3eb'


def patch(path):
    original = path.read_bytes()
    if hashlib.sha256(original).hexdigest() != EXPECTED:
        raise ValueError('Jam UTXO metadata source does not match the reviewed pinned runtime')
    source = original.decode() + '''

# Paperclip preserves the upstream input-ownership state machine.
import os as _paperclip_os
if _paperclip_os.name == "nt":
    from paperclip_jam.windows_metadata import utxo_file_lock
    UTXOMetadataStore._exclusive_file_lock = utxo_file_lock
'''
    compile(source, str(path), 'exec')
    with path.open('w', encoding='utf-8', newline='\n') as output:
        output.write(source)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    patch(parser.parse_args().source)
