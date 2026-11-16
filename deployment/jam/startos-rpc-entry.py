"""Keep rotating node credentials outside the unprivileged Jam runtime.

Only this small supervisor reads the dependency mount. The RPC listener runs as
jmrpc (1001); Jam reads only the separate filter client cookie as jm (1000).
"""
import os
from pathlib import Path
import secrets
import signal
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit


def read_cookie(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, 'rb') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError('Node credential file is not regular')
        value = stream.read(4097)
    if len(value) > 4096:
        raise ValueError('Node credential file is too large')
    value = value.strip()
    if b':' not in value or any(byte < 33 or byte > 126 for byte in value):
        raise ValueError('Invalid node credential format')
    user, password = value.split(b':', 1)
    if not user or not password:
        raise ValueError('Incomplete node credentials')
    return value


def write_cookie(path, value, owner, mode):
    # Use file descriptors for ownership/mode, never follow a credential symlink.
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.cookie-')
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(value + b'\n')
            stream.flush()
            if owner is not None:
                os.fchown(stream.fileno(), *owner)
            os.fchmod(stream.fileno(), mode)
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def refresh_cookie(source, destination, owner=(1001, 1001)):
    value = read_cookie(source)
    if not destination.exists() or read_cookie(destination) != value:
        write_cookie(destination, value, owner, 0o400)


def filter_environment(node_url):
    parsed = urlsplit(node_url)
    if (parsed.scheme != 'http' or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.path not in ('', '/')
            or parsed.query or parsed.fragment or parsed.port is None or not 1 <= parsed.port <= 65535
            or any(char.isspace() for char in node_url)):
        raise ValueError('Invalid internal node RPC address')
    return {'PATH': os.environ.get('PATH', '/usr/local/bin:/usr/bin:/bin'),
        'PYTHONUNBUFFERED': '1', 'PYTHONDONTWRITEBYTECODE': '1',
        'JM_RPC_FILTER_LISTEN': '127.0.0.1:28187', 'JM_RPC_FILTER_MODE': 'enforce',
        'JM_RPC_FILTER_NODE_URL': node_url,
        'JM_RPC_FILTER_NODE_COOKIE': '/private-rpc/node.cookie',
        'JM_RPC_FILTER_CLIENT_COOKIE': '/rpc-filter/client.cookie'}


def directory(path, owner, mode):
    path.mkdir(mode=mode, exist_ok=True)
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fchown(fd, *owner)
        os.fchmod(fd, mode)
    finally:
        os.close(fd)


def main():
    if os.geteuid() != 0:
        raise ValueError('Credential supervisor requires its isolated root container')
    env = filter_environment(os.environ.get('PAPERCLIP_NODE_RPC_URL', ''))
    source = Path('/mnt/xbt-node/.cookie')
    private = Path('/private-rpc')
    shared = Path('/rpc-filter')
    directory(private, (1001, 1001), 0o700)
    directory(shared, (1001, 1000), 0o750)
    client = shared / 'client.cookie'
    if client.exists() or client.is_symlink():
        value = read_cookie(client)  # Reject unexpected/symlinked persisted state.
    else:
        value = ('jmrpcfilter:' + secrets.token_hex(32)).encode('ascii')
    write_cookie(client, value, (1001, 1000), 0o440)
    refresh_cookie(source, private / 'node.cookie')
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, stop)
    child = subprocess.Popen(['setpriv', '--no-new-privs', '--bounding-set=-all',
        '--inh-caps=-all', '--reuid=1001', '--regid=1001', '--clear-groups',
        sys.executable, '/usr/local/lib/jm-xbt/rpc_filter.py'],
        env=env, stdin=subprocess.DEVNULL, close_fds=True)
    try:
        while not stopping and child.poll() is None:
            refresh_cookie(source, private / 'node.cookie')
            time.sleep(2)
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=20)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
    return 0 if stopping else child.returncode or 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError):
        # Never print file contents, request headers, or arbitrary exception text.
        print('JoinBlaket RPC credential setup or refresh failed.', file=sys.stderr)
        sys.exit(1)
