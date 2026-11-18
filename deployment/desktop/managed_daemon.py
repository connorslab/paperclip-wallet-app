"""Native daemon ownership and one-use browser handoff for desktop shells.

This module never selects an installed wallet or starts anything on import.
Callers supply the packaged executable and an application data root explicitly.
"""
from contextlib import ExitStack
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

if os.name == 'nt':
    from windows import private_storage as windows_storage


SESSION_MARKER = b'paperclip-desktop-session-v1\n'


class StartupError(RuntimeError):
    """Public-safe error: never include daemon output, credentials or responses."""


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        fp.close()
        raise StartupError('The local daemon redirected its readiness check.')


def default_data_root():
    if os.name == 'nt':
        return windows_storage.default_data_root()
    if sys.platform == 'darwin':
        return Path.home() / 'Library' / 'Application Support' / 'Paperclip'
    if sys.platform.startswith('linux'):
        base = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local' / 'share')))
        if not base.is_absolute():
            raise StartupError('The application data location must be absolute.')
        return base / 'paperclip'
    raise StartupError('This desktop runner requires Linux or macOS.')


def private_directory(path):
    if os.name == 'nt':
        return windows_storage.private_directory(path)
    # Do not silently adopt shared or symlinked wallet storage or change its mode.
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) & 0o077):
        raise StartupError('The application data directory must be private and owned by you.')


def private_file(path, flags=os.O_RDONLY, public_metadata=False):
    if os.name == 'nt':
        if flags != os.O_RDONLY:
            raise StartupError('Use the native Windows writer for desktop state.')
        return windows_storage.read_private_file(path)
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
    abrupt death. An explicitly supplied Jars runtime shares this lifetime.
    """

    def __init__(self, binary, root, startup_timeout=30, shutdown_timeout=20, jam_runtime=None, tor_binary=None):
        self.binary = Path(binary).resolve(strict=True)
        # Validate Windows spelling before normalization can hide an alias.
        self.root = windows_storage.local_path(root) if os.name == 'nt' else Path(root).absolute()
        self.data = self.root / 'wallet'
        self.startup_timeout = startup_timeout
        self.shutdown_timeout = shutdown_timeout
        self.process = None
        self._lock = None
        self.endpoint = None
        self.recovery_required = False
        self._marker_identity = None
        self._windows_session = None
        self.tor_binary = tor_binary
        self.tor = None
        self.jam_runtime = jam_runtime
        self.jam = None

    def _mark_session(self):
        if os.name == 'nt':
            self._windows_session = windows_storage.SessionRecord(self.root / 'session.state')
            self.recovery_required = self._windows_session.begin()
            return
        marker = self.root / 'session.active'
        try:
            with private_file(marker) as file:
                info = os.fstat(file.fileno())
                if file.read(64) != SESSION_MARKER:
                    raise StartupError('The desktop session record needs recovery.')
                self._marker_identity = (info.st_dev, info.st_ino)
            self.recovery_required = True
        except FileNotFoundError:
            with private_file(marker, os.O_RDWR | os.O_CREAT | os.O_EXCL) as file:
                file.write(SESSION_MARKER)
                file.flush()
                os.fsync(file.fileno())
                info = os.fstat(file.fileno())
                self._marker_identity = (info.st_dev, info.st_ino)
            self._sync_root()

    def _sync_root(self):
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def _clear_session(self):
        if os.name == 'nt':
            try:
                self._windows_session.finish()
            except Exception:
                raise StartupError('The wallet closed, but its recovery warning could not be cleared.') from None
            return
        marker = self.root / 'session.active'
        try:
            with private_file(marker) as file:
                info = os.fstat(file.fileno())
                if ((info.st_dev, info.st_ino) != self._marker_identity
                        or file.read(64) != SESSION_MARKER):
                    raise StartupError('The desktop session record changed; keep checking recovery.')
            marker.unlink()
            self._sync_root()
            self._marker_identity = None
        except Exception:
            raise StartupError('The wallet closed, but its recovery warning could not be cleared.') from None

    def start(self):
        if os.name != 'nt' and not (sys.platform == 'darwin' or sys.platform.startswith('linux')):
            raise StartupError('This desktop platform is unsupported.')
        if self.process is not None or self._lock is not None:
            raise StartupError('This desktop session has already been started.')
        try:
            private_directory(self.root)
            private_directory(self.data)
            # Outside wallet/: deleting a wallet must not remove the launcher lock.
            if os.name == 'nt':
                self._lock = ExitStack()
                self._lock.enter_context(windows_storage.exclusive_file(self.root / 'launcher.lock'))
            else:
                self._lock = private_file(self.root / 'launcher.lock', os.O_RDWR | os.O_CREAT)
                try:
                    fcntl.flock(self._lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise StartupError('Paperclip is already open for this data directory.') from None
            # Write before launch, clear only after an observed clean close.
            # Launcher death and forced daemon shutdown leave this public marker.
            self._mark_session()
            try:
                previous = (self.data / 'barkd.url').lstat()
                previous_identity = (previous.st_dev, previous.st_ino)
            except FileNotFoundError:
                previous_identity = None
            # Inherited auth, bind, node, TLS, loader and proxy overrides must not
            # alter the packaged daemon. Persisted wallet settings remain intact.
            env = {key: os.environ[key] for key in ('PATH', 'HOME', 'TMPDIR', 'LANG') if key in os.environ}
            if os.name == 'nt':
                env.update({key: os.environ[key] for key in ('SystemRoot', 'TEMP', 'TMP') if key in os.environ})
            if self.jam_runtime is not None:
                from managed_jam import ManagedJam
                self.jam = ManagedJam(*self.jam_runtime, self.root / 'jars', tor_binary=self.tor_binary)
                env.update(self.jam.start())
            elif self.tor_binary is not None:
                from managed_tor import ManagedTor
                self.tor = ManagedTor(self.tor_binary, self.root / 'tor')
                binding = self.tor.start()
                env['BARKD_LIGHTNING_TOR_PROXY'] = f'socks5h://127.0.0.1:{binding["socks_port"]}'
            self.process = subprocess.Popen([
                str(self.binary), '--quiet', '--no-logfile', '--datadir', str(self.data),
                '--host', '127.0.0.1', '--port', '0', '--exit-on-stdin-close', '--desktop-handoff',
            ], env=env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, close_fds=True,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
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
                    if self.jam is not None:
                        self.jam.ensure_running()
                    if self.tor is not None:
                        self.tor.ensure_running()
                    self.endpoint = endpoint
                    return endpoint
                except HTTPError as error:
                    error.close()
                    raise StartupError('The local daemon rejected its authenticated readiness check.') from None
                except (FileNotFoundError, URLError, TimeoutError):
                    time.sleep(0.05)
                except OSError as error:
                    # Windows publishes a private file before its writer closes
                    # the exclusive handle. Retry sharing/lock races only, never
                    # turn an ACL or ownership rejection into a startup success.
                    if os.name != 'nt' or getattr(error, 'winerror', None) not in (32, 33):
                        raise
                    time.sleep(0.05)
            raise StartupError('The local wallet service did not become ready in time.')
        except Exception as error:
            self.close()
            if isinstance(error, StartupError):
                raise
            if os.name == 'nt' and isinstance(error, windows_storage.UnsafeStorage):
                # These messages are fixed storage-policy text, never file
                # contents, paths, authentication or an underlying OS error.
                raise StartupError(str(error)) from None
            raise StartupError('The local wallet service could not start. Check its private data and executable.') from None
        except BaseException:
            self.close()
            raise

    def ensure_running(self):
        if self.endpoint is None or self.process is None or self.process.poll() is not None:
            raise StartupError('The local wallet stopped unexpectedly. Open it again to recover.')
        if self.jam is not None:
            self.jam.ensure_running()
        if self.tor is not None:
            self.tor.ensure_running()

    def browser_url(self):
        """Return an expiring, single-use URL; caller must not log or persist it."""
        if self.endpoint is None or self.process is None or self.process.poll() is not None:
            raise StartupError('Open the desktop wallet before opening its browser window.')
        self.ensure_running()
        try:
            with private_file(self.data / 'auth_token') as credential:
                token = credential.read(128).decode('ascii').strip()
            if not re.fullmatch(r'[A-Za-z0-9_-]{44}', token):
                raise StartupError('The saved local authentication is malformed.')
            request = Request(self.endpoint + '/api/desktop/handoff/new', method='POST',
                              headers={'Authorization':'Bearer ' + token}, data=b'')
            http = build_opener(ProxyHandler({}), NoRedirects())
            with http.open(request, timeout=3) as response:
                result = json.loads(response.read(4096))
            code = result.get('code')
            if not isinstance(code, str) or not re.fullmatch(r'[A-Za-z0-9_-]{44}', code) or result.get('expires_in') != 60:
                raise StartupError('The local daemon returned an invalid browser handoff.')
            return self.endpoint + '/#desktop-handoff=' + code
        except HTTPError as error:
            error.close()
            raise StartupError('Desktop browser sign-in could not be prepared.') from None
        except Exception:
            raise StartupError('Desktop browser sign-in could not be prepared.') from None

    def close(self):
        was_running = self.process is not None and self.process.poll() is None
        try:
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
                # Stop accepting wallet requests and drain them before closing Jam.
                # Never clear the shared recovery marker if either child failed.
                try:
                    if self.jam is not None:
                        self.jam.close()
                finally:
                    if self.tor is not None and self._lock is not None:
                        try:
                            self.tor.ensure_running()
                        finally:
                            self.tor.close()
            if was_running and self.endpoint is not None and self.process.returncode == 0:
                self._clear_session()
        finally:
            self.endpoint = None
            try:
                if self._windows_session is not None:
                    self._windows_session.close()
                    self._windows_session = None
            finally:
                if self._lock is not None:
                    self._lock.close()
                    self._lock = None

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()
