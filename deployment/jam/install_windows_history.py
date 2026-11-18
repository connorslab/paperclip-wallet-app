"""Select private native history storage for one reviewed Jam source revision."""
import argparse
import hashlib
from pathlib import Path

EXPECTED = 'b3282982a187cfe83b2b5cca043fd4f690f6be6ce68a19bd653a9d8239549653'


def patch(path):
    original = path.read_bytes()
    if hashlib.sha256(original).hexdigest() != EXPECTED:
        raise ValueError('Jam history source does not match the reviewed pinned runtime')
    source = original.decode() + '''

if os.name == "nt":
    from paperclip_jam.windows_history import install as _paperclip_install_history
    _paperclip_install_history(globals())
'''
    compile(source, str(path), 'exec')
    with path.open('w', encoding='utf-8', newline='\n') as output:
        output.write(source)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    patch(parser.parse_args().source)
