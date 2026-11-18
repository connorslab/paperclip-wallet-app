"""Owned Jam child for native desktop packaging (not a standalone installer).

Run with the pinned runtime's Python in isolated mode and an explicit private root.
Stdout contains one public readiness object; stdin closure requests graceful exit.
No keys, credentials, responses or exception details are written to either stream.
"""
import argparse
import asyncio
from contextlib import contextmanager
import json
import logging
import os
from pathlib import Path
import socket
import ssl
import stat
import sys
import threading

sys.dont_write_bytecode = True

if os.name == 'nt':
    if not getattr(sys, 'frozen', False):
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'desktop'))
        sys.path.insert(0, str(Path(__file__).resolve().parent))
    from windows import private_storage as native_storage
    from paperclip_jam.windows_storage import ensure_private_directory
else:
    import fcntl


def private_directory(path):
    if os.name == 'nt':
        return ensure_private_directory(path)
    if not path.is_absolute() or any(item.is_symlink() for item in (path, *path.parents)):
        raise ValueError('Invalid runtime directory')
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError('Runtime directory is not private')


def private_file(path):
    if os.name == 'nt':
        with native_storage.read_private_file(path):
            return
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) & 0o077):
        raise ValueError('Runtime file is not private')


def runtime_environment(root, tor=None):
    environment = {key: os.environ[key] for key in ('PATH', 'LANG', 'TMPDIR') if key in os.environ}
    environment.update(HOME=str(root), JOINMARKET_DATA_DIR=str(root), JOINMARKET_CONFIG_FILE=str(root / 'config.toml'))
    if os.name == 'nt':
        import win32api
        windows = Path(win32api.GetWindowsDirectory())
        temporary = root / 'tmp'
        private_directory(temporary)
        environment = {'SystemRoot':str(windows), 'WINDIR':str(windows),
            'PATH':str(windows / 'System32'), 'TEMP':str(temporary), 'TMP':str(temporary),
            'USERPROFILE':str(root), 'HOME':str(root), 'JOINMARKET_DATA_DIR':str(root),
            'JOINMARKET_CONFIG_FILE':str(root / 'config.toml')}
    if tor is not None:
        socks, control, cookie = tor
        if not 1 <= socks <= 65535 or not 1 <= control <= 65535 or socks == control:
            raise ValueError('Invalid owned Tor ports')
        if not cookie.is_absolute():
            raise ValueError('Owned Tor requires an absolute cookie path')
        private_file(cookie)
        if cookie.stat().st_size != 32:
            raise ValueError('Invalid owned Tor cookie')
        environment.update(TOR__SOCKS_HOST='127.0.0.1', TOR__SOCKS_PORT=str(socks),
            TOR__CONTROL_ENABLED='true', TOR__CONTROL_HOST='127.0.0.1',
            TOR__CONTROL_PORT=str(control), TOR__COOKIE_PATH=str(cookie), TOR__STREAM_ISOLATION='true')
    return environment


@contextmanager
def entry_lock(root):
    if os.name == 'nt':
        with native_storage.exclusive_file(root / 'desktop.lock'):
            yield
        return
    fd = os.open(root / 'desktop.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise ValueError('Invalid runtime lock')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


async def serve(root, tor=None):
    # Do not silently use upstream's default RPC node after the owner saves a
    # different connection. Activation requires the pending restricted runtime.
    if os.path.lexists(root / 'node-connection.json'):
        raise ValueError('Saved node settings require explicit runtime activation')
    # Sanitize before importing upstream settings. Never inherit a different node,
    # data directory, credentials, proxy, loader or logging configuration.
    environment = runtime_environment(root, tor)
    os.environ.clear()
    os.environ.update(environment)
    if getattr(sys, 'frozen', False):
        import bitcointx
        import certifi
        library_name = 'libsecp256k1.dll' if os.name == 'nt' else 'libsecp256k1.dylib' if sys.platform == 'darwin' else 'libsecp256k1.so'
        library = Path(sys._MEIPASS) / library_name
        if not library.is_file():
            raise ValueError('Missing bundled crypto library')
        bitcointx.set_custom_secp256k1_path(str(library))
        os.environ['SSL_CERT_FILE'] = certifi.where()
        os.environ['SSL_CERT_DIR'] = str(Path(sys._MEIPASS) / 'no-host-ca-directory')
    from loguru import logger
    logger.remove()
    logger.disable('')
    logging.disable(logging.CRITICAL)
    from jmcore.process_hardening import harden_current_process
    from jmcore.settings import reset_settings
    from jmwalletd.cli import _generate_self_signed_cert
    from jmwalletd.app import create_app
    import uvicorn

    harden_current_process()
    reset_settings()
    tls = root / 'ssl'
    private_directory(tls)
    cert, key = tls / 'cert.pem', tls / 'key.pem'
    present = [os.path.lexists(path) for path in (cert, key)]
    if any(present) and not all(present):
        raise ValueError('Incomplete TLS identity; do not silently rotate it')
    if not any(present):
        _generate_self_signed_cert(tls)
        if os.name != 'nt':
            cert.chmod(0o600)
    private_file(cert)
    private_file(key)
    # Check the preserved key/certificate pair before the app can load wallet state.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    app = create_app(data_dir=root)
    logger.remove()  # create_app installs its own upstream log sink.
    if not hasattr(app.state, 'paperclip_payments'):
        raise ValueError('The pinned Paperclip companion is required')
    server = uvicorn.Server(uvicorn.Config(app, host='127.0.0.1', port=0,
        ssl_certfile=str(cert), ssl_keyfile=str(key), access_log=False,
        log_config=None, log_level='critical', timeout_graceful_shutdown=20))
    loop = asyncio.get_running_loop()
    parent_closed = threading.Event()

    def parent_lifetime():
        # Avoid holding Python's buffered stdin lock during signal shutdown.
        try:
            os.read(0, 1)  # EOF or an unexpected message closes this child.
        except OSError:
            pass
        parent_closed.set()
        try:
            loop.call_soon_threadsafe(setattr, server, 'should_exit', True)
        except RuntimeError:
            pass  # The server already exited and closed the event loop.

    threading.Thread(target=parent_lifetime, daemon=True).start()
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(128)
        task = asyncio.create_task(server.serve(sockets=[listener]))
        while not server.started and not task.done() and not server.should_exit:
            await asyncio.sleep(0.02)
        if server.started and not server.should_exit:
            print(json.dumps({'ready': True, 'endpoint': f'https://127.0.0.1:{listener.getsockname()[1]}'}), flush=True)
        await task
        if not server.started and not parent_closed.is_set():
            raise ValueError('Jam startup did not complete')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', type=Path)
    setup_mode = parser.add_mutually_exclusive_group()
    setup_mode.add_argument('--check-node', action='store_true')
    setup_mode.add_argument('--configure-node', action='store_true')
    parser.add_argument('--tor-socks-port', type=int)
    parser.add_argument('--tor-control-port', type=int)
    parser.add_argument('--tor-cookie-path', type=Path)
    args = parser.parse_args()
    if args.check_node:
        if args.data_dir is not None or args.tor_control_port is not None or args.tor_cookie_path is not None:
            parser.error('Node checks do not open wallet storage or the Tor controller.')
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from paperclip_jam.node_setup import check_pipe
        return check_pipe(sys.stdin.buffer, sys.stdout, args.tor_socks_port)
    if args.data_dir is None:
        parser.error('Supply the private Jars data directory.')
    if args.configure_node:
        if args.tor_control_port is not None or args.tor_cookie_path is not None:
            parser.error('Node setup does not open the Tor controller.')
        os.umask(0o077)
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from paperclip_jam.node_setup import check_pipe, report_failure
        from paperclip_jam import node_store
        try:
            private_directory(args.data_dir)
            with entry_lock(args.data_dir):
                return check_pipe(sys.stdin.buffer, sys.stdout, args.tor_socks_port,
                    admit=lambda: node_store.admit(args.data_dir),
                    save=lambda settings: node_store.save_initial(args.data_dir, settings))
        except BlockingIOError:
            return report_failure(sys.stdout, 'setup_in_use')
        except (OSError, ValueError):
            return report_failure(sys.stdout, 'unsafe_storage')
    tor = (args.tor_socks_port, args.tor_control_port, args.tor_cookie_path)
    if any(value is not None for value in tor) and any(value is None for value in tor):
        parser.error('Supply the complete owned Tor binding.')
    if all(value is None for value in tor):
        tor = None
    os.umask(0o077)
    private_directory(args.data_dir)
    # Acquire before TLS generation, create_app, journal loading or stale-plan
    # reconciliation. A competing child must not mutate the running one's files.
    with entry_lock(args.data_dir):
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        asyncio.run(serve(args.data_dir, tor))


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        # Source locations and exception classes help diagnose frozen-runtime
        # failures without rendering arguments, credentials, paths or locals.
        frames = []
        trace = error.__traceback__
        while trace is not None:
            frames.append(f'{Path(trace.tb_frame.f_code.co_filename).name}:{trace.tb_lineno}')
            trace = trace.tb_next
        print('Jars runtime diagnostic: ' + json.dumps({'type': type(error).__name__, 'frames': frames}), file=sys.stderr)
        print('The private Jam runtime could not start or close safely.', file=sys.stderr)
        sys.exit(1)
