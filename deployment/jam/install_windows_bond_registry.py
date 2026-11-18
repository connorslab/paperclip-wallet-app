"""Private native bond metadata I/O, retaining pinned ownership/migration rules."""
import argparse
import hashlib
from pathlib import Path

EXPECTED = 'fb58a17abf523807a3063cf50190d3b40d59aad366b5764923e1a4701e487451'


def patch(path):
    original = path.read_bytes()
    if hashlib.sha256(original).hexdigest() != EXPECTED:
        raise ValueError('Jam bond registry source does not match the reviewed pinned runtime')
    source = original.decode()
    for variable in ('registry_path','legacy_path','per_wallet_path'):
        source = source.replace(f'{variable}.read_text()', f'_paperclip_read_registry({variable})')
    source += '''

if os.name == "nt":
    from paperclip_jam.windows_storage import read_private_file as _paperclip_read_registry
    from paperclip_jam.windows_storage import atomic_write_private as _paperclip_write_registry

    def save_registry(registry, data_dir, fingerprint=None):
        path = get_registry_path(data_dir, fingerprint)
        _paperclip_write_registry(path, registry.model_dump_json(indent=2).encode("utf-8"))
else:
    def _paperclip_read_registry(path):
        return path.read_text()
'''
    compile(source, str(path), 'exec')
    with path.open('w', encoding='utf-8', newline='\n') as output:
        output.write(source)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    patch(parser.parse_args().source)
