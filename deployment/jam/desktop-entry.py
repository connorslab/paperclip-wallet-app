"""Owned POSIX Jam child for native desktop packaging (not a standalone installer).

Run with the pinned runtime's Python in isolated mode and an explicit private root.
Stdout contains one public readiness object; stdin closure requests graceful exit.
No keys, credentials, responses or exception details are written to either stream.
"""
import argparse
import asyncio
import fcntl
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


def private_directory(path):
    if not path.is_absolute() or any(item.is_symlink() for item in (path, *path.parents)):
        raise ValueError('Invalid runtime directory')
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError('Runtime directory is not private')


def private_file(path):
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) & 0o077):
        raise ValueError('Runtime file is not private')


async def serve(root):
    # Sanitize before importing upstream settings. Never inherit a different node,
    # data directory, credentials, proxy, loader or logging configuration.
    environment = {key: os.environ[key] for key in ('PATH', 'LANG', 'TMPDIR') if key in os.environ}
    environment.update(HOME=str(root), JOINMARKET_DATA_DIR=str(root), JOINMARKET_CONFIG_FILE=str(root / 'config.toml'))
    os.environ.clear()
    os.environ.update(environment)
    if getattr(sys, 'frozen', False):
        import bitcointx
        import certifi
        library = Path(sys._MEIPASS) / 'libsecp256k1.dylib'
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
    parser.add_argument('--data-dir', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    private_directory(args.data_dir)
    # Acquire before TLS generation, create_app, journal loading or stale-plan
    # reconciliation. A competing child must not mutate the running one's files.
    fd = os.open(args.data_dir / 'desktop.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise ValueError('Invalid runtime lock')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        asyncio.run(serve(args.data_dir))
    finally:
        os.close(fd)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('The private Jam runtime could not start or close safely.', file=sys.stderr)
        sys.exit(1)
