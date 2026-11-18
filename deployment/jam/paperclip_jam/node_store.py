"""Private native node settings with explicit, version-bound replacement."""
import asyncio
from contextlib import contextmanager
from dataclasses import dataclass
import json
import logging
import os
from pathlib import Path
import re
import secrets
import stat

from paperclip_jam.node_setup import MAX_INPUT, NodeSettings, NodeSetupError, verify, report_failure

if os.name == 'nt':
    from windows import private_storage as native

NAME = 'node-connection.json'


@dataclass(frozen=True, repr=False)
class StoredNode:
    connection_id: str
    settings: NodeSettings


@contextmanager
def directory(root):
    root = Path(root)
    if not root.is_absolute() or '..' in root.parts or any(p.is_symlink() for p in (root, *root.parents)):
        raise NodeSetupError('unsafe_storage')
    if os.name == 'nt':
        # Reads do not create a missing directory. The launcher admits the
        # private directory before it acquires the shared desktop lifetime lock.
        if not root.is_dir():
            raise FileNotFoundError()
        with native.ancestors(root / NAME):
            native.private_directory(root)
            yield None
    else:
        fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            info = os.fstat(fd)
            if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
                raise NodeSetupError('unsafe_storage')
            yield fd
        finally:
            os.close(fd)


def admit(root):
    try:
        _admit(root)
    except (OSError, ValueError):
        raise NodeSetupError('unsafe_storage') from None


def _admit(root):
    """Initial setup only. Existing legacy configuration requires a reviewed migration."""
    root = Path(root)
    with directory(root):
        for path in root.iterdir():
            if path.is_symlink():
                raise NodeSetupError('unsafe_storage')
            if path.name not in ('desktop.lock', 'ssl', 'wallets', 'paperclip', 'tmp'):
                raise NodeSetupError('existing_setup')
        if os.path.lexists(root / NAME) or os.path.lexists(root / 'config.toml'):
            raise NodeSetupError('existing_setup')
        # No implicit node switch for a directory that already owns wallets or
        # recovery journals. These files must never be modified by setup.
        for name in ('wallets', 'paperclip', 'tmp'):
            path = root / name
            if os.path.lexists(path) and (path.is_symlink() or not path.is_dir() or any(path.iterdir())):
                raise NodeSetupError('existing_setup')


def save_initial(root, settings):
    """Call under desktop.lock, after live verification; flush before acknowledging.

    Interrupted creation stays in place and must be inspected, never silently
    replaced. Readers reject partial documents, aliases and permissive storage.
    """
    root = Path(root)
    admit(root)
    identity = secrets.token_hex(16)
    record = {'version': 1, 'connection_id': identity, 'settings':
        {key: getattr(settings, key) for key in ('endpoint', 'username', 'password', 'tor', 'ca_pem')}}
    encoded = json.dumps(record, separators=(',', ':'), ensure_ascii=False).encode()
    if len(encoded) > MAX_INPUT:
        raise NodeSetupError('invalid_settings')
    try:
        with directory(root) as parent:
            if os.name == 'nt':
                native.create_private_file(root / NAME, encoded)
            else:
                fd = os.open(NAME, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                    0o600, dir_fd=parent)
                with os.fdopen(fd, 'wb') as stream:
                    stream.write(encoded)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.fsync(parent)
    except (OSError, ValueError):
        raise NodeSetupError('storage_failure') from None
    return {'saved': True, 'active': False, 'connection_id': identity}


def load(root):
    root = Path(root)
    try:
        with directory(root) as parent:
            if os.name == 'nt':
                with native.read_private_file(root / NAME) as stream:
                    encoded = stream.read(MAX_INPUT + 1)
            else:
                fd = os.open(NAME, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
                with os.fdopen(fd, 'rb') as stream:
                    info = os.fstat(stream.fileno())
                    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                            or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) & 0o077):
                        raise NodeSetupError('unsafe_storage')
                    encoded = stream.read(MAX_INPUT + 1)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        raise NodeSetupError('unsafe_storage') from None
    if len(encoded) > MAX_INPUT:
        raise NodeSetupError('storage_failure')
    try:
        record = json.loads(encoded)
        if (not isinstance(record, dict) or set(record) != {'version', 'connection_id', 'settings'}
                or type(record['version']) is not int or record['version'] != 1
                or not isinstance(record['connection_id'], str)
                or not re.fullmatch('[0-9a-f]{32}', record['connection_id'])):
            raise ValueError()
        settings = NodeSettings.parse(record['settings'])
        settings.tls_context()
        return StoredNode(record['connection_id'], settings)
    except (ValueError, TypeError, KeyError, NodeSetupError):
        raise NodeSetupError('storage_failure') from None


def require_current(root, expected):
    """A successful or uncertain previous save invalidates the old review."""
    if not isinstance(expected, str) or not re.fullmatch('[0-9a-f]{32}', expected):
        raise NodeSetupError('review_required')
    current = load(root)
    if current is None or current.connection_id != expected:
        raise NodeSetupError('stale_review')
    return current


def replace_verified(root, settings, expected):
    """Caller holds desktop.lock and has verified the reviewed replacement node.

    Only the connection record changes. Wallets, recovery journals and legacy
    configuration remain untouched. A failed flush after rename is uncertain;
    never roll back or automatically repeat it.
    """
    root = Path(root)
    require_current(root, expected)
    identity = secrets.token_hex(16)
    encoded = json.dumps({'version': 1, 'connection_id': identity, 'settings':
        {key: getattr(settings, key) for key in ('endpoint', 'username', 'password', 'tor', 'ca_pem')}},
        separators=(',', ':'), ensure_ascii=False).encode()
    if len(encoded) > MAX_INPUT:
        raise NodeSetupError('invalid_settings')
    try:
        with directory(root) as parent:
            if os.name == 'nt':
                require_current(root, expected)
                native.atomic_write_private(root / NAME, encoded)
            else:
                temporary = '.node-' + secrets.token_hex(16) + '.tmp'
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                    0o600, dir_fd=parent)
                replaced = False
                try:
                    with os.fdopen(fd, 'wb') as stream:
                        stream.write(encoded)
                        stream.flush()
                        os.fsync(stream.fileno())
                    require_current(root, expected)
                    os.replace(temporary, NAME, src_dir_fd=parent, dst_dir_fd=parent)
                    replaced = True
                    os.fsync(parent)
                finally:
                    if not replaced:
                        os.unlink(temporary, dir_fd=parent)
    except (OSError, ValueError):
        raise NodeSetupError('storage_failure') from None
    return {'saved': True, 'active': False, 'connection_id': identity}


def replace_pipe(root, source, destination, socks_port=None):
    """Private native request; caller must hold the complete Jars lifetime lock."""
    logging.disable(logging.CRITICAL)
    try:
        encoded = source.read(MAX_INPUT + 1)
        if len(encoded) > MAX_INPUT:
            raise NodeSetupError('invalid_settings')
        try:
            request = json.loads(encoded)
            if (not isinstance(request, dict)
                    or set(request) != {'settings', 'expected_connection_id', 'confirmed'}
                    or request['confirmed'] is not True):
                raise NodeSetupError('review_required')
            expected = request['expected_connection_id']
            require_current(root, expected)
            settings = NodeSettings.parse(request['settings'])
        except (ValueError, UnicodeError, TypeError):
            raise NodeSetupError('invalid_settings') from None
        result = asyncio.run(verify(settings, socks_port))
        result.update(replace_verified(root, settings, expected))
    except NodeSetupError as error:
        return report_failure(destination, error.code)
    except Exception:
        return report_failure(destination, 'unavailable')
    destination.write(json.dumps(result) + '\n')
    destination.flush()
    return 0


def public_state(root):
    """Inspect saved configuration without network, writes or secret metadata.

    A saved record is not evidence of a live connection. Existing wallet state
    without this record requires a reviewed migration, never initial setup.
    """
    root = Path(root)
    stored = load(root)
    if stored is not None:
        return {'state': 'saved', 'can_configure': False, 'connection_id': stored.connection_id,
            'transport': 'tor' if stored.settings.tor else
                'https' if stored.settings.endpoint.lower().startswith('https:') else 'loopback',
            'live_connection': 'not_checked'}
    if os.path.lexists(root):
        try:
            admit(root)
        except NodeSetupError as error:
            if error.code == 'existing_setup':
                return {'state': 'existing_wallet', 'can_configure': False, 'live_connection': 'not_checked'}
            raise
    return {'state': 'not_configured', 'can_configure': True, 'live_connection': 'not_checked'}


def status_pipe(root, destination):
    """Only fixed status, transport and random public identity leave this pipe."""
    try:
        result = public_state(root)
        code = 0
    except (NodeSetupError, OSError, ValueError) as error:
        code = 2
        failure = error if isinstance(error, NodeSetupError) else NodeSetupError('unsafe_storage')
        result = {'state': 'needs_attention', 'can_configure': False, 'live_connection': 'not_checked',
            'code': failure.code, 'message': str(failure)}
    destination.write(json.dumps(result) + '\n')
    destination.flush()
    return code
