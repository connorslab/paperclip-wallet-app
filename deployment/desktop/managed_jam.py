"""Own the packaged Jam child and verify its loopback TLS before wallet startup."""
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import time
from urllib.request import HTTPSHandler, ProxyHandler, build_opener

from managed_daemon import NoRedirects, StartupError, private_file
from pipe_io import read_available


class ManagedJam:
    def __init__(self, python, entry, root, startup_timeout=30, shutdown_timeout=25):
        # Preserve the venv interpreter path: resolving its symlink loses the venv.
        self.python = Path(python).absolute()
        self.entry = Path(entry).resolve(strict=True) if entry is not None else None
        if not self.python.is_file():
            raise StartupError('The bundled Jars interpreter is unavailable.')
        self.root = Path(root).absolute()
        self.startup_timeout, self.shutdown_timeout = startup_timeout, shutdown_timeout
        self.process = None
        self.endpoint = None

    def start(self):
        if self.process is not None:
            raise StartupError('This Jars session was already started.')
        environment = {key: os.environ[key] for key in ('PATH', 'LANG', 'TMPDIR') if key in os.environ}
        if os.name == 'nt':
            import win32api
            windows = Path(win32api.GetWindowsDirectory())
            # Windows needs its real system directory before Python/TLS starts.
            # Never inherit node, proxy, Python loader or TLS overrides.
            environment = {'SystemRoot': str(windows), 'WINDIR': str(windows),
                           'PATH': str(windows / 'System32')}
        try:
            command = [str(self.python)] if self.entry is None else [str(self.python), '-I', '-B', str(self.entry)]
            self.process = subprocess.Popen(command + ['--data-dir', str(self.root)],
                env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, close_fds=True,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
            pending = b''
            deadline = time.monotonic() + self.startup_timeout
            while b'\n' not in pending:
                if self.process.poll() is not None:
                    raise StartupError('The bundled Jars service exited during startup.')
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise StartupError('The bundled Jars service did not become ready in time.')
                chunk = read_available(self.process.stdout.fileno(), 1025, min(remaining, 0.1))
                if chunk is not None:
                    if not chunk or len(pending) + len(chunk) > 1024:
                        raise StartupError('The bundled Jars service returned invalid readiness data.')
                    pending += chunk
            value = json.loads(pending)
            endpoint = value.get('endpoint')
            match = re.fullmatch(r'https://127\.0\.0\.1:([0-9]{1,5})', endpoint or '')
            if set(value) != {'ready', 'endpoint'} or value['ready'] is not True or not match or not 1 <= int(match[1]) <= 65535:
                raise StartupError('The bundled Jars service returned an invalid local address.')
            with private_file(self.root / 'ssl' / 'cert.pem') as file:
                certificate = file.read(16_385)
            if len(certificate) > 16_384 or b'PRIVATE KEY' in certificate:
                raise StartupError('The bundled Jars certificate is invalid.')
            context = ssl.create_default_context(cadata=certificate.decode('ascii'))
            http = build_opener(ProxyHandler({}), NoRedirects(), HTTPSHandler(context=context))
            with http.open(endpoint + '/api/v1/paperclip/capabilities', timeout=3) as response:
                features = json.loads(response.read(4097))
            if features.get('version') != 2 or self.process.poll() is not None:
                raise StartupError('The bundled Jars service is incompatible or stopped.')
            self.endpoint = endpoint
            return {'BARKD_JOINBLAKET_URL': endpoint,
                    'BARKD_JOINBLAKET_CA_FILE': str(self.root / 'ssl' / 'cert.pem')}
        except BaseException as error:
            self.close()
            if isinstance(error, (KeyboardInterrupt, SystemExit, StartupError)):
                raise
            raise StartupError('The bundled Jars service could not start with verified TLS.') from None

    def ensure_running(self):
        if self.endpoint is None or self.process is None or self.process.poll() is not None:
            raise StartupError('Your Jars service stopped unexpectedly. Reopen Paperclip and check payment history.')

    def close(self):
        if self.process is None:
            return
        was_running = self.process.poll() is None
        was_ready = self.endpoint is not None
        forced = False
        try:
            self.process.stdin.close()
            if self.process.poll() is None:
                try:
                    self.process.wait(timeout=self.shutdown_timeout)
                except subprocess.TimeoutExpired:
                    forced = True
                    self.process.kill()
                    self.process.wait(timeout=5)
            if forced or (was_ready and (not was_running or self.process.returncode != 0)):
                raise StartupError('Jars did not close cleanly. Check its payment history before sending again.')
        finally:
            self.process.stdout.close()
            self.endpoint = None
