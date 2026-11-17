"""Private runtime ownership and public-certificate handoff to Paperclip."""
from contextlib import asynccontextmanager, contextmanager
import os
from pathlib import Path
import stat
import tempfile

from cryptography import x509

if os.name == 'nt':
    from windows.private_storage import exclusive_file
else:
    import fcntl


def export_certificate(data_dir, destination):
    source = Path(data_dir) / 'ssl' / 'cert.pem'
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError('Jam certificate must be a regular file')
        certificate = stream.read(16_385)
    if len(certificate) > 16_384 or b'PRIVATE KEY' in certificate:
        raise ValueError('Invalid public certificate')
    x509.load_pem_x509_certificate(certificate)
    destination = Path(destination)
    if any(path.is_symlink() for path in (destination, *destination.parents)):
        raise ValueError('Unsafe certificate handoff path')
    # Host packaging creates this directory, writable only by the Jam uid.
    if not destination.parent.is_dir():
        raise ValueError('Jam public certificate volume is not mounted')
    fd, temporary = tempfile.mkstemp(dir=destination.parent, prefix='.cert-')
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(certificate)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o644)
        os.replace(temporary, destination)
        directory_fd = os.open(destination.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def runtime_lock(data_dir):
    # The upstream daemon state is process-local. Multiple API workers must not
    # enter its lifespan concurrently, even when they use different transports.
    path = Path(data_dir) / 'paperclip' / 'runtime.lock'
    if os.name == 'nt':
        with exclusive_file(path):
            yield
    else:
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        finally:
            os.close(fd)


def install_hosting(app, data_dir):
    original = app.router.lifespan_context

    @asynccontextmanager
    async def lifespan(current):
        with runtime_lock(data_dir):
            target = os.environ.get('PAPERCLIP_JAM_PUBLIC_CERT_FILE')
            if target:
                export_certificate(data_dir, target)
            async with original(current):
                yield

    app.router.lifespan_context = lifespan
