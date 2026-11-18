"""Install batch correlation only into the reviewed, pinned RPC filter."""
import hashlib
from pathlib import Path
import sys

EXPECTED = '444fedcbab403843dcf4bce0b1a22bd57bf33d98983d72cfa95841d51bf094d8'
MARKER = '\nif __name__ == "__main__":'


def patch(path):
    original = path.read_bytes()
    if hashlib.sha256(original).hexdigest() != EXPECTED:
        raise ValueError('RPC filter source does not match the reviewed pinned runtime')
    source = original.decode()
    if source.count(MARKER) != 1:
        raise ValueError('RPC filter entry point changed')
    source = source.replace(MARKER,
        '\nfrom rpc_batch import install as install_paperclip_batch\ninstall_paperclip_batch(globals())\n' + MARKER)
    compile(source, str(path), 'exec')
    with path.open('w', encoding='utf-8', newline='\n') as output:
        output.write(source)


if __name__ == '__main__':
    patch(Path(sys.argv[1]))
