"""Keep pinned identity semantics while selecting private native Windows I/O."""
import argparse
import hashlib
from pathlib import Path

EXPECTED = '118518f495c723906d73afde7cf0124aa35e5ec08ea9d4d2753aa618ae868f60'


def patch(path):
    original = path.read_bytes()
    if hashlib.sha256(original).hexdigest() != EXPECTED:
        raise ValueError('Jam metadata source does not match the reviewed pinned runtime')
    source = original.decode().replace(
        'from jmcore.secure_files import atomic_write_private',
        'from jmcore.secure_files import atomic_write_private, read_private_file')
    source = source.replace('json.loads(meta_path(mnemonic_file).read_text())',
        'json.loads(read_private_file(meta_path(mnemonic_file)) if os.name == "nt" else meta_path(mnemonic_file).read_text())')
    source += '\n\nif os.name == "nt":\n    from paperclip_jam.windows_metadata import metadata_lock\n'
    compile(source, str(path), 'exec')
    with path.open('w', encoding='utf-8', newline='\n') as output:
        output.write(source)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    patch(parser.parse_args().source)
