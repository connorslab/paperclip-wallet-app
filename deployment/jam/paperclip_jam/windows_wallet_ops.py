"""Native reservation for the pinned Jam wallet create/recovery lifecycle."""
from contextlib import contextmanager, ExitStack

from windows.private_storage import exclusive_file, local_path
from paperclip_jam.windows_storage import ensure_private_directory


@contextmanager
def reserve_wallet_path(wallet_path):
    wallet_path = local_path(wallet_path)
    ensure_private_directory(wallet_path.parent)
    with ExitStack() as ownership:
        try:
            ownership.enter_context(exclusive_file(wallet_path.parent / '.wallet-operation.lock'))
        except BlockingIOError as error:
            raise FileExistsError('Wallet operation already in progress') from error
        if wallet_path.exists():
            raise FileExistsError('Wallet file already exists')
        yield
