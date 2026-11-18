"""Private native sidecar ownership for the pinned Jam wallet identity API."""
from contextlib import contextmanager

from windows.private_storage import exclusive_file, local_path
from paperclip_jam.windows_storage import ensure_private_directory


@contextmanager
def metadata_lock(mnemonic_file, *, nonblocking=False):
    mnemonic_file = local_path(mnemonic_file)
    suffix = '.meta.recovery.lock' if nonblocking else '.meta.lock'
    path = mnemonic_file.with_name(mnemonic_file.name + suffix)
    ensure_private_directory(path.parent)
    with exclusive_file(path, nonblocking=nonblocking):
        yield


@contextmanager
def utxo_file_lock(store):
    path = local_path(store._flock_path)
    ensure_private_directory(path.parent)
    with exclusive_file(path, nonblocking=False):
        yield
