"""POSIX daemon ownership for a future desktop shell; no browser/token handoff yet.

This module never selects an installed wallet or starts anything on import.
Callers supply the packaged executable and an application data root explicitly.
Windows needs native ACL and locking support before using an equivalent runner.
"""
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, ProxyHandler, HTTPRedirectHandler

try:
    import fcntl
except ImportError:
    fcntl = None


class StartupError(RuntimeError):
    """Public-safe error: never include daemon output, credentials or responses."""


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        fp.close()
        raise StartupError('The local daemon redirected its readiness check.')


def default_data_root():
    if sys.platform == 'darwin':
        return Path.home() / 'Library' / 'Application Support' / 'Paperclip'
    if sys.platform.startswith('linux'):
        base = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local' / 'share')))
        if not base.is_absolute():
            raise StartupError('The application data location must be absolute.')
        return base / 'paperclip'
    raise StartupError('This desktop runner requires Linux or macOS.')


def private_directory(path):
    # Do not silently adopt shared or symlinked wallet storage or change its mode.
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) & 0o077):
        raise StartupError('The application data directory must be private and owned by you.')


def private_file(path, flags=os.O_RDONLY, public_metadata=False):
    fd = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) & (0o022 if public_metadata else 0o077)):
            raise StartupError('The local daemon metadata must be private regular files.')
        return os.fdopen(fd, 'r+b' if flags & os.O_RDWR else 'rb')
    except BaseException:
        os.close(fd)
        raise


def local_endpoint(value):
    try:
        address = urlsplit(value)
        if (address.scheme == 'http' and address.hostname == '127.0.0.1'
                and address.port and value == f'http://127.0.0.1:{address.port}'):
            return value
    except ValueError:
        pass
    raise StartupError('The daemon did not publish a valid local address.')


class ManagedDaemon:
    """Own one child; never attach to, terminate or authenticate an unknown daemon.

    The shell must call close on normal quit. Its lifetime pipe also closes on
    abrupt death; bundled Jam/Tor supervision and browser authentication are separate.
    """

    def __init__(self, binary, root, startup_timeout=30, shutdown_timeout=20):
        self.binary = Path(binary).resolve(strict=True)
        self.root = Path(root).absolute()
        self.data = self.root / 'wallet'
        self.startup_timeout = startup_timeout
        self.shutdown_timeout = shutdown_timeout
        self.process = None
        self._lock = None
        self.endpoint = None

    def start(self):
        if os.name != 'posix' or not (sys.platform == 'darwin' or sys.platform.startswith('linux')):
            raise StartupError('This desktop runner requires Linux or macOS.')
        if self.process is not None or self._lock is not None:
            raise StartupError('This desktop session has already been started.')
        try:
            private_directory(self.root)
            private_directory(self.data)
            # Outside wallet/: deleting a wallet must not remove the launcher lock.
            self._lock = private_file(self.root / 'launcher.lock', os.O_RDWR | os.O_CREAT)
            try:
                fcntl.flock(self._lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise StartupError('Paperclip is already open for this data directory.') from None
            try:
                previous = (self.data / 'barkd.url').lstat()
                previous_identity = (previous.st_dev, previous.st_ino)
            except FileNotFoundError:
                previous_identity = None
            # Inherited auth, bind, node, TLS, loader and proxy overrides must not
            # alter the packaged daemon. Persisted wallet settings remain intact.
            env = {key: os.environ[key] for key in ('PATH', 'HOME', 'TMPDIR', 'LANG') if key in os.environ}
            self.process = subprocess.Popen([
                str(self.binary), '--quiet', '--no-logfile', '--datadir', str(self.data),
                '--host', '127.0.0.1', '--port', '0', '--exit-on-stdin-close',
            ], env=env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, close_fds=True)
            http = build_opener(ProxyHandler({}), NoRedirects())
            deadline = time.monotonic() + self.startup_timeout
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise StartupError('The wallet service exited during startup. No existing service was stopped.')
                try:
                    with private_file(self.data / 'barkd.url') as discovery:
                        info = os.fstat(discovery.fileno())
                        if (info.st_dev, info.st_ino) == previous_identity:
                            time.sleep(0.05)
                            continue
                        endpoint = local_endpoint(discovery.read(256).decode('ascii'))
                    # A fresh address alone is insufficient: a competing manual
                    # launch could win the daemon lock before our child starts.
                    # The PID is public metadata inside our private directory;
                    # existing daemon lock files may be 0644, never group-writable.
                    with private_file(self.data / 'barkd.lock', public_metadata=True) as pid_file:
                        if pid_file.read(64).decode('ascii').strip() != str(self.process.pid):
                            time.sleep(0.05)
                            continue
                    with private_file(self.data / 'auth_token') as credential:
                        token = credential.read(128).decode('ascii').strip()
                    if not re.fullmatch(r'[A-Za-z0-9_-]{44}', token):
                        raise StartupError('The saved local authentication is malformed.')
                    request = Request(endpoint + '/api/v1/wallet', headers={'Authorization': 'Bearer ' + token})
                    with http.open(request, timeout=min(1, max(0.01, deadline - time.monotonic()))) as response:
                        result = json.loads(response.read(4096))
                    if not isinstance(result, dict) or 'fingerprint' not in result:
                        raise StartupError('The local daemon returned an invalid readiness response.')
                    if self.process.poll() is not None:
                        raise StartupError('The wallet service stopped during startup.')
                    self.endpoint = endpoint
                    return endpoint
                except HTTPError as error:
                    error.close()
                    raise StartupError('The local daemon rejected its authenticated readiness check.') from None
                except (FileNotFoundError, URLError, TimeoutError):
                    time.sleep(0.05)
            raise StartupError('The local wallet service did not become ready in time.')
        except Exception as error:
            self.close()
            if isinstance(error, StartupError):
                raise
            raise StartupError('The local wallet service could not start. Check its private data and executable.') from None
        except BaseException:
            self.close()
            raise

    def close(self):
        try:
            if self.process is not None and self.process.stdin is not None:
                self.process.stdin.close()
            if self.process is not None and self.process.poll() is None:
                try:
                    self.process.wait(timeout=self.shutdown_timeout)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
                    raise StartupError('The wallet service required forced shutdown; check recovery on next launch.') from None
        finally:
            self.endpoint = None
            if self._lock is not None:
                self._lock.close()
                self._lock = None

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()
