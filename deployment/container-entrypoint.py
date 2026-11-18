#!/usr/bin/env python3
"""Container bootstrap. Authentication only; wallet keys are created by barkd."""
import base64
import hmac
import os
from pathlib import Path
import re
import stat
import sys


def prepare_auth(datadir, app_password=None):
    datadir = Path(datadir)
    datadir.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Work through checked handles: path-based chmod/read could otherwise follow
    # a replaced link or modify another file through an alias in a restored volume.
    directory = os.open(datadir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        owner = os.fstat(directory)
        if owner.st_uid != os.geteuid():
            raise ValueError('Wallet directory must be owned by the service user')
        os.fchmod(directory, 0o700)
        expected = None
        if app_password:
            if not re.fullmatch(r'[0-9a-fA-F]{64}', app_password):
                raise ValueError('APP_PASSWORD must contain 32 random bytes encoded as hex')
            expected = base64.urlsafe_b64encode(b'\0' + bytes.fromhex(app_password)).decode().rstrip('=')
        try:
            fd = os.open('auth_token', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        except FileNotFoundError:
            if expected:
                fd = os.open('auth_token', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=directory)
                with os.fdopen(fd, 'w') as handle:
                    handle.write(expected)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.fsync(directory)
        else:
            try:
                info = os.fstat(fd)
                if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                        or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077):
                    raise ValueError('Authentication file must be private, owned and unlinked')
                raw = os.read(fd, 45)
            finally:
                os.close(fd)
            try:
                current = raw.decode('ascii')
                decoded = base64.b64decode(current, altchars=b'-_', validate=True)
            except (ValueError, UnicodeError):
                raise ValueError('Invalid persisted authentication token') from None
            if (len(raw) != 44 or len(decoded) != 33 or decoded[0] != 0
                    or base64.urlsafe_b64encode(decoded).decode() != current):
                raise ValueError('Invalid persisted authentication token')
            if expected and not hmac.compare_digest(current, expected):
                raise ValueError('App password differs from restored token; resolve explicitly before startup')
    finally:
        os.close(directory)
    # Without a platform password, barkd generates its native random token.
    # Never create, replace, or derive a mnemonic here.


def main():
    os.umask(0o077)
    datadir = os.environ.get('BARKD_DATADIR', '/data/wallet')
    if os.environ.get('APP_PASSWORD'):
        os.environ['BARKD_UI_PLATFORM'] = 'umbrel'
    prepare_auth(datadir, os.environ.pop('APP_PASSWORD', None))
    os.environ.pop('APP_SEED', None)
    os.environ['BARKD_DATADIR'] = datadir
    os.environ.setdefault('BARKD_BIND_HOST', '0.0.0.0')
    os.environ.setdefault('BARKD_BIND_PORT', '3000')
    for unsafe in ('BARKD_NO_AUTH', 'BARKD_DANGEROUSLY_ALLOW_REMOTE_NO_AUTH', 'BARKD_EXPOSE_MNEMONIC'):
        os.environ.pop(unsafe, None)
    os.execvp('paperclip-walletd', ['paperclip-walletd'])


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError):
        sys.exit('Wallet bootstrap failed. Check volume permissions and app password/backup consistency; no keys were replaced.')
