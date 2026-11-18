"""Owned native Tor runtime. Callers must supply a reviewed packaged executable.

No discovery or attachment to a system Tor. Local control readiness is separate
from network bootstrap. This component does not create or access wallet keys.
"""
import os
from pathlib import Path
import re
import shutil
import secrets
import socket
import subprocess
import sys
import time

from managed_daemon import StartupError, private_directory, private_file
from tor_runtime import validate as validate_runtime

if os.name == 'nt':
    import win32api
    from windows.private_storage import atomic_write_private, prepare_child_file_owner


def packaged_binary(root):
    try:
        return validate_runtime(root)[0]
    except (OSError, ValueError):
        # Never expose archive metadata, paths or decoder input in the shell.
        raise StartupError('Paperclip’s bundled Tor files are missing or damaged. Reinstall Paperclip, then try again. Your saved wallets have not been changed.') from None


class Control:
    """Bounded synchronous subset; no event subscription or bulk data commands."""
    def __init__(self, connection):
        self.connection = connection
        self.reader = connection.makefile('rb')

    def command(self, command):
        if '\r' in command or '\n' in command:
            raise StartupError('Invalid local Tor control command.')
        self.connection.sendall(command.encode('ascii') + b'\r\n')
        lines, size = [], 0
        for _ in range(16):
            line = self.reader.readline(4097)
            size += len(line)
            if size > 8192 or not line.endswith(b'\r\n') or len(line) > 4096:
                raise StartupError('Tor returned an invalid control reply.')
            # Unexpected events, errors and data blocks are never interpreted
            # as successful replies. No raw reply is placed in diagnostics.
            if line[:3] != b'250' or line[3:4] not in (b' ', b'-'):
                raise StartupError('Tor rejected the local control request.')
            try:
                lines.append(line[4:-2].decode('ascii'))
            except UnicodeError:
                raise StartupError('Tor returned an invalid control reply.') from None
            if line[3:4] == b' ':
                return lines
        raise StartupError('Tor returned too many control reply lines.')

    def close(self):
        try:
            self.reader.close()
        finally:
            self.connection.close()


class ManagedTor:
    def __init__(self, binary, root, startup_timeout=15, shutdown_timeout=10):
        self.binary = Path(binary).resolve(strict=True)
        self.root = Path(root).absolute()
        self.startup_timeout, self.shutdown_timeout = startup_timeout, shutdown_timeout
        self.process = self.control = self.session = None
        self.socks_port = self.control_port = None
        self.cookie = None

    def start(self, *, network_enabled=True):
        if self.process is not None:
            raise StartupError('This Tor session was already started.')
        stage = 'preparing private storage'
        try:
            private_directory(self.root)
            data = self.root / 'data'
            private_directory(data)
            # A unique private session prevents old control files from directing
            # this controller to a different process after an interrupted start.
            self.session = self.root / ('control-' + secrets.token_hex(16))
            private_directory(self.session)
            self.cookie = self.session / 'cookie'
            control_file = self.session / 'address'
            torrc = self.session / 'torrc'
            # Do not load a user's system torrc, defaults, bridges or listeners.
            if os.name == 'nt':
                atomic_write_private(torrc, b'')
            else:
                with private_file(torrc, os.O_RDWR | os.O_CREAT | os.O_EXCL) as file:
                    file.write(b'')
            environment = {key:os.environ[key] for key in ('PATH', 'LANG', 'TMPDIR') if key in os.environ}
            if sys.platform.startswith('linux'):
                # The expert bundle ships its libraries beside Tor without an
                # ELF RUNPATH. Use only that explicit executable's directory;
                # never inherit the caller's loader path or LD_PRELOAD.
                environment['LD_LIBRARY_PATH'] = str(self.binary.parent)
            if os.name == 'nt':
                stage = 'assigning private child-file ownership'
                prepare_child_file_owner()
                windows = Path(win32api.GetWindowsDirectory())
                environment = {'SystemRoot':str(windows), 'WINDIR':str(windows), 'PATH':str(windows / 'System32')}
            args = [str(self.binary), '-f', str(torrc), '--defaults-torrc', str(torrc),
                '--RunAsDaemon', '0', '--ClientOnly', '1', '--DataDirectory', str(data),
                '--SocksPort', '127.0.0.1:auto', '--ControlPort', '127.0.0.1:auto',
                '--CookieAuthentication', '1', '--CookieAuthFile', str(self.cookie),
                '--CookieAuthFileGroupReadable', '0', '--ControlPortWriteToFile', str(control_file),
                '--SafeLogging', '1', '--Log', 'err stdout', '--AvoidDiskWrites', '1',
                '--DisableNetwork', '1',
                '--__OwningControllerProcess', str(os.getpid())]
            stage = 'starting its bundled process'
            self.process = subprocess.Popen(args, env=environment, stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
            stage = 'reading its private control files'
            deadline = time.monotonic() + self.startup_timeout
            while True:
                if self.process.poll() is not None:
                    raise StartupError('The bundled Tor service exited during startup.')
                if time.monotonic() >= deadline:
                    raise StartupError('Tor did not publish its private control address in time.')
                try:
                    with private_file(control_file) as file:
                        address = file.read(129)
                    with private_file(self.cookie) as file:
                        cookie = file.read(33)
                except FileNotFoundError:
                    time.sleep(0.02)
                    continue
                match = re.fullmatch(rb'PORT=127\.0\.0\.1:([0-9]{1,5})\r?\n?', address)
                if not match or not 1 <= int(match[1]) <= 65535 or len(cookie) != 32:
                    raise StartupError('Tor returned invalid private control metadata.')
                self.control_port = int(match[1])
                break
            stage = 'connecting to its local controller'
            connection = socket.create_connection(('127.0.0.1', self.control_port), timeout=3)
            self.control = Control(connection)
            stage = 'authenticating its local controller'
            self.control.command('AUTHENTICATE ' + cookie.hex())
            stage = 'establishing controller ownership'
            self.control.command('TAKEOWNERSHIP')
            self.control.command('RESETCONF __OwningControllerProcess')
            self.ensure_running()
            if network_enabled:
                stage = 'opening its SOCKS connection'
                self.enable_network()
            return {'socks_port':self.socks_port, 'control_port':self.control_port, 'cookie_path':str(self.cookie)}
        except BaseException as error:
            self.close()
            if isinstance(error, (KeyboardInterrupt, SystemExit, StartupError)):
                raise
            # Only fixed stage names are shown; exceptions can contain private
            # paths, control metadata or operating-system input.
            if isinstance(error, TimeoutError):
                raise StartupError(f'Tor timed out while {stage}. Close and reopen Paperclip to try again.') from None
            raise StartupError(f'Tor could not finish {stage} securely. Close and reopen Paperclip to try again.') from None

    def enable_network(self):
        self.ensure_running()
        self.control.command('SETCONF DisableNetwork=0')
        reply = self.control.command('GETINFO net/listeners/socks')
        matches = [re.fullmatch(r'net/listeners/socks="127\.0\.0\.1:([0-9]{1,5})"', line) for line in reply]
        ports = [int(match[1]) for match in matches if match]
        if len(ports) != 1 or not 1 <= ports[0] <= 65535:
            raise StartupError('Tor did not publish one loopback SOCKS listener.')
        self.socks_port = ports[0]
        return self.socks_port

    def ensure_running(self):
        if self.process is None or self.process.poll() is not None or self.control is None:
            raise StartupError('Tor stopped. Reopen Paperclip before using an onion connection.')

    def bootstrap_progress(self):
        self.ensure_running()
        try:
            lines = self.control.command('GETINFO status/bootstrap-phase')
            progress = [re.search(r'^status/bootstrap-phase=(?:NOTICE|WARN) BOOTSTRAP PROGRESS=([0-9]{1,3})(?: |$)', line) for line in lines]
            values = [int(match[1]) for match in progress if match]
            if len(values) != 1 or not 0 <= values[0] <= 100:
                raise StartupError('Tor returned invalid bootstrap progress.')
            return values[0]
        except (OSError, UnicodeError):
            raise StartupError('Tor bootstrap progress is unavailable.') from None

    def close(self):
        # Only the child started by this instance can be stopped. Closing the
        # owning control connection also stops Tor after controller failure.
        if self.control is not None:
            try:
                if self.process.poll() is None:
                    self.control.command('SIGNAL SHUTDOWN')
            except (OSError, UnicodeError, StartupError):
                pass
            finally:
                self.control.close()
                self.control = None
        if self.process is not None and self.process.poll() is None:
            try:
                self.process.wait(timeout=self.shutdown_timeout)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=3)
        if self.session is not None:
            shutil.rmtree(self.session)
            self.session = None
        self.socks_port = self.control_port = self.cookie = None
