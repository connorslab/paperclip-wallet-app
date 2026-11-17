"""Build-time Windows adapter installation for one reviewed upstream revision."""
import argparse
import hashlib
from pathlib import Path

EXPECTED = 'b962ffe6dd7d9b91f2d550044e6658b3b08d04da27c876ad613c5b3c45bd202d'
ADAPTER = '''

# Paperclip native desktop storage; POSIX code above remains unchanged.
if os.name == "nt":
    from paperclip_jam.windows_storage import (
        ensure_private_directory, ensure_private_file, read_private_file,
        ensure_sensitive_directory, ensure_sensitive_file, read_sensitive_file,
        atomic_write_private, atomic_write_sensitive_file, create_private_file_exclusive,
    )
'''


def patch(path):
    original = path.read_bytes()
    if hashlib.sha256(original).hexdigest() != EXPECTED:
        raise ValueError('Jam private-file source does not match the reviewed pinned runtime')
    source = original.decode() + ADAPTER
    compile(source, str(path), 'exec')
    with path.open('w', encoding='utf-8', newline='\n') as output:
        output.write(source)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    patch(parser.parse_args().source)
