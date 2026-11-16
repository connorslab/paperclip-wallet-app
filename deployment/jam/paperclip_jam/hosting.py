"""Private runtime ownership and public-certificate handoff to Paperclip."""
from contextlib import asynccontextmanager
import fcntl
import os
from pathlib import Path
import stat
import tempfile

from cryptography import x509


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


def install_hosting(app, data_dir):
    original = app.router.lifespan_context

    @asynccontextmanager
    async def lifespan(current):
        fd = os.open(Path(data_dir) / 'paperclip' / 'runtime.lock',
            os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            # The legacy daemon state is process-local. Multiple API workers
            # cannot safely coordinate its maker/taker admission flags.
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            target = os.environ.get('PAPERCLIP_JAM_PUBLIC_CERT_FILE')
            if target:
                export_certificate(data_dir, target)
            async with original(current):
                yield
        finally:
            os.close(fd)

    app.router.lifespan_context = lifespan
