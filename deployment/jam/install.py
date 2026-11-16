"""Build-time installation only. Refuse an unreviewed upstream API revision."""
import hashlib
from pathlib import Path
import sys

EXPECTED = '36a806bef8bd18530452bb49b54314ba3cd147e3765268d6302825996a11a175'
MARKER = '    app.include_router(wallet_router, prefix="/api/v1")'


def patch(path):
    original = path.read_bytes()
    if hashlib.sha256(original).hexdigest() != EXPECTED:
        raise ValueError('Jam API source does not match the reviewed pinned runtime')
    source = original.decode()
    if source.count(MARKER) != 1:
        raise ValueError('Jam route registration changed')
    source = source.replace(MARKER,
        '    from paperclip_jam.api import install as install_paperclip\n'
        '    install_paperclip(app, state)\n\n' + MARKER)
    compile(source, str(path), 'exec')
    path.write_text(source)


if __name__ == '__main__':
    patch(Path(sys.argv[1]))
