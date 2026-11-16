"""Private SOCKS client for the server wallet's CLN/LND onion connections."""
import os
from pathlib import Path
import subprocess


def arguments(env):
    # An explicit platform proxy takes precedence. Never change its route or
    # silently fall back to a direct connection when Tor is unavailable.
    if env.get('BARKD_LIGHTNING_TOR_PROXY'):
        return None
    root = Path(env.get('BARKD_DATADIR', '/data/wallet'))
    for path in (root, root / 'tor'):
        if path.is_symlink():
            raise ValueError('Tor storage must not be a symbolic link')
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.chmod(0o700)
    return ['tor', '--RunAsDaemon', '0', '--ClientOnly', '1',
            '--DataDirectory', str(root / 'tor'), '--SocksPort', '127.0.0.1:9050',
            '--SocksPolicy', 'accept 127.0.0.1', '--SocksPolicy', 'reject *',
            '--SafeLogging', '1', '--Log', 'err stdout', '--AvoidDiskWrites', '1']


def start(args, env):
    child = subprocess.Popen(args, stdin=subprocess.DEVNULL)
    env['BARKD_LIGHTNING_TOR_PROXY'] = 'socks5h://127.0.0.1:9050'
    return child
