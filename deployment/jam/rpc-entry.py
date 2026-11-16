"""Start the restricted filter with the selected Umbrel node, never its daemon."""
import os
import sys
from urllib.parse import urlsplit


def environment(values):
    # Retain only interpreter/process configuration; no APP_* credentials reach
    # a child except the selected node's dedicated filter configuration.
    clean = {key: values[key] for key in ('PATH', 'LANG', 'PYTHONUNBUFFERED') if key in values}
    clean.update(JM_RPC_FILTER_LISTEN='0.0.0.0:28187', JM_RPC_FILTER_MODE='enforce',
        JM_RPC_FILTER_CLIENT_COOKIE='/rpc-filter/client.cookie')
    for prefix in ('BITCOIN', 'KNOTS_BLAKE2B', 'BITCOIN_KNOTS'):
        host, port = values.get(f'NODE_{prefix}_IP', ''), values.get(f'NODE_{prefix}_PORT', '')
        if not host or not port:
            continue
        if not port.isascii() or not port.isdecimal() or not 1 <= int(port) <= 65535:
            raise ValueError('Invalid node RPC port')
        if any(char in host for char in '/@?#\\') or any(char.isspace() for char in host):
            raise ValueError('Invalid node RPC host')
        parsed = urlsplit(f'http://{host}:{port}')
        if parsed.hostname is None or parsed.username is not None or parsed.port != int(port):
            raise ValueError('Invalid node RPC address')
        username, password = values.get(f'NODE_{prefix}_USER', ''), values.get(f'NODE_{prefix}_PASS', '')
        if not username or not password:
            raise ValueError('Selected node RPC credentials are missing')
        clean.update(JM_RPC_FILTER_NODE_URL=parsed.geturl(), JM_RPC_FILTER_NODE_USER=username,
            JM_RPC_FILTER_NODE_PASS=password)
        return clean
    raise ValueError('Choose a compatible BLAKE2b Bitcoin node in the Paperclip package settings')


if __name__ == '__main__':
    try:
        env = environment(os.environ)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    os.execve(sys.executable, [sys.executable, '/usr/local/lib/jm-xbt/rpc_filter.py'], env)
