"""Native Windows storage for the owned desktop launcher.

Existing storage is verified, never repaired by changing its permissions. Handles
keep ancestor directories from being renamed during creation and lock acquisition.
Only local paths, current-user ownership and user/SYSTEM access are accepted.
"""
from contextlib import contextmanager, ExitStack
import ctypes
from ctypes import wintypes
import msvcrt
import os
from pathlib import Path
import secrets

import ntsecuritycon
import pywintypes
import win32api
import win32con
import win32file
import win32security
from win32com.shell import shell, shellcon


class UnsafeStorage(ValueError):
    pass


def default_data_root():
    return local_path(Path(shell.SHGetFolderPath(0, shellcon.CSIDL_LOCAL_APPDATA, None, 0)) / 'Paperclip')


def user_sid():
    token = win32security.OpenProcessToken(win32api.GetCurrentProcess(), win32con.TOKEN_QUERY)
    try:
        return win32security.GetTokenInformation(token, win32security.TokenUser)[0]
    finally:
        token.Close()


def prepare_child_file_owner():
    """Keep implicit child-created files owned by this process's user.

    Elevated Windows processes can default to Administrators as object owner.
    Set only this process token's default owner before starting owned children;
    do not change its identity, groups, privileges, DACL or any existing file.
    All existing private-file validation remains mandatory.
    """
    token = win32security.OpenProcessToken(win32api.GetCurrentProcess(),
        win32con.TOKEN_QUERY | win32con.TOKEN_ADJUST_DEFAULT)
    try:
        owner = win32security.GetTokenInformation(token, win32security.TokenUser)[0]
        if win32security.GetTokenInformation(token, win32security.TokenOwner) != owner:
            win32security.SetTokenInformation(token, win32security.TokenOwner, owner)
        if win32security.GetTokenInformation(token, win32security.TokenOwner) != owner:
            raise UnsafeStorage('Child storage cannot be assigned to the current user.')
    finally:
        token.Close()


def private_attributes():
    owner = win32security.ConvertSidToStringSid(user_sid())
    descriptor = win32security.ConvertStringSecurityDescriptorToSecurityDescriptor(
        f'O:{owner}D:P(A;OICI;FA;;;{owner})(A;OICI;FA;;;SY)', win32security.SDDL_REVISION_1)
    attributes = pywintypes.SECURITY_ATTRIBUTES()
    attributes.SECURITY_DESCRIPTOR = descriptor
    attributes.bInheritHandle = False
    return attributes


def validate_handle(handle, directory, private=True):
    info = win32file.GetFileInformationByHandle(handle)
    if info[0] & win32con.FILE_ATTRIBUTE_REPARSE_POINT:
        raise UnsafeStorage('Linked application storage is not supported.')
    if bool(info[0] & win32con.FILE_ATTRIBUTE_DIRECTORY) != directory:
        raise UnsafeStorage('Unexpected application storage type.')
    if not directory and info[7] != 1:
        raise UnsafeStorage('Shared application files are not supported.')
    if not private:
        return
    descriptor = win32security.GetSecurityInfo(handle, win32security.SE_FILE_OBJECT,
        win32security.OWNER_SECURITY_INFORMATION | win32security.DACL_SECURITY_INFORMATION)
    owner = user_sid()
    if descriptor.GetSecurityDescriptorOwner() != owner:
        raise UnsafeStorage('Application storage must be owned by the current user.')
    dacl = descriptor.GetSecurityDescriptorDacl()
    if dacl is None or dacl.GetAceCount() == 0:
        raise UnsafeStorage('Application storage requires explicit private access.')
    allowed = {win32security.ConvertSidToStringSid(owner), 'S-1-5-18'}
    owner_access = False
    for index in range(dacl.GetAceCount()):
        ace = dacl.GetAce(index)
        if ace[0][0] != win32security.ACCESS_ALLOWED_ACE_TYPE or win32security.ConvertSidToStringSid(ace[2]) not in allowed:
            raise UnsafeStorage('Application storage grants unexpected access.')
        if ace[2] == owner and not ace[0][1] & win32con.INHERIT_ONLY_ACE:
            owner_access = True
    if not owner_access:
        raise UnsafeStorage('Application storage does not grant its owner access.')


def local_path(path):
    path = Path(path)
    if not path.is_absolute() or len(path.drive) != 2 or path.drive[1] != ':' or '..' in path.parts:
        raise UnsafeStorage('Use an absolute local application storage path.')
    if any(':' in part or part.endswith(('.', ' ')) for part in path.parts[1:]):
        raise UnsafeStorage('Ambiguous application storage paths are not supported.')
    if win32file.GetDriveType(path.anchor) not in (2, 3):  # removable or fixed local drive
        raise UnsafeStorage('Application storage must be on a local drive.')
    return path


@contextmanager
def ancestors(path):
    handles = []
    try:
        for parent in reversed(path.parents):
            # Metadata-only handles do not enforce Windows delete sharing.
            handle = win32file.CreateFile(str(parent), win32con.READ_CONTROL | ntsecuritycon.FILE_READ_ATTRIBUTES | ntsecuritycon.FILE_LIST_DIRECTORY,
                win32con.FILE_SHARE_READ | win32con.FILE_SHARE_WRITE, None, win32con.OPEN_EXISTING,
                win32file.FILE_FLAG_OPEN_REPARSE_POINT | win32con.FILE_FLAG_BACKUP_SEMANTICS, None)
            handles.append(handle)
            validate_handle(handle, directory=True, private=False)
        yield
    finally:
        for handle in reversed(handles):
            handle.Close()


def private_directory(path):
    path = local_path(path)
    with ancestors(path):
        try:
            win32file.CreateDirectory(str(path), private_attributes())
        except pywintypes.error as error:
            if error.winerror != 183:  # ERROR_ALREADY_EXISTS; verify instead of changing ACLs.
                raise
        handle = win32file.CreateFile(str(path), win32con.READ_CONTROL | ntsecuritycon.FILE_READ_ATTRIBUTES,
            win32con.FILE_SHARE_READ | win32con.FILE_SHARE_WRITE, None, win32con.OPEN_EXISTING,
            win32file.FILE_FLAG_OPEN_REPARSE_POINT | win32con.FILE_FLAG_BACKUP_SEMANTICS, None)
        try:
            validate_handle(handle, directory=True)
        finally:
            handle.Close()


@contextmanager
def exclusive_file(path, *, nonblocking=True):
    path = local_path(path)
    with ancestors(path):
        handle = win32file.CreateFile(str(path), win32con.GENERIC_READ | win32con.GENERIC_WRITE | win32con.READ_CONTROL,
            win32con.FILE_SHARE_READ | win32con.FILE_SHARE_WRITE, private_attributes(), win32con.OPEN_ALWAYS,
            win32file.FILE_FLAG_OPEN_REPARSE_POINT, None)
        try:
            validate_handle(handle, directory=False)
            overlap = pywintypes.OVERLAPPED()
            try:
                win32file.LockFileEx(handle, win32con.LOCKFILE_EXCLUSIVE_LOCK | (win32con.LOCKFILE_FAIL_IMMEDIATELY if nonblocking else 0), 1, 0, overlap)
            except pywintypes.error as error:
                if error.winerror == 33:  # ERROR_LOCK_VIOLATION
                    raise BlockingIOError('Application storage is already in use.') from None
                raise
            yield handle
        finally:
            # Closing the handle releases the kernel lock, including after a crash.
            handle.Close()


@contextmanager
def writable_private_file(path):
    """Hold checked, non-replaceable storage while SQLite owns byte-range locks.

    This does not take a competing byte lock or truncate an existing file. New
    files have explicit owner/ACLs; existing files are never permission-repaired.
    """
    path = local_path(path)
    if win32api.GetVolumeInformation(path.anchor)[-1] != 'NTFS':
        raise UnsafeStorage('Private database storage requires a local NTFS volume.')
    with ancestors(path):
        access = win32con.GENERIC_READ | win32con.GENERIC_WRITE | win32con.READ_CONTROL
        sharing = win32con.FILE_SHARE_READ | win32con.FILE_SHARE_WRITE
        flags = win32file.FILE_FLAG_OPEN_REPARSE_POINT | win32file.FILE_FLAG_WRITE_THROUGH
        created = True
        try:
            handle = win32file.CreateFile(str(path), access, sharing, private_attributes(),
                win32con.CREATE_NEW, flags, None)
        except pywintypes.error as error:
            if error.winerror != 80:
                raise
            created = False
            handle = win32file.CreateFile(str(path), access, sharing, None,
                win32con.OPEN_EXISTING, flags, None)
        try:
            validate_handle(handle, directory=False)
            if created:
                win32file.FlushFileBuffers(handle)
            yield handle
        finally:
            handle.Close()


class _RenameInfo(ctypes.Structure):
    _fields_ = [('flags', wintypes.DWORD), ('root', wintypes.HANDLE),
                ('name_length', wintypes.DWORD), ('name', wintypes.WCHAR * 1)]


def _rename_private_handle(handle, destination):
    # FileRenameInfoEx: replace the directory entry while existing readers keep
    # the old file. The staging handle stays open across replacement and flush.
    encoded = str(destination).encode('utf-16-le')
    size = max(ctypes.sizeof(_RenameInfo), _RenameInfo.name.offset + len(encoded) + 2)
    buffer = ctypes.create_string_buffer(size)
    info = _RenameInfo.from_buffer(buffer)
    info.flags = 0x1 | 0x2  # REPLACE_IF_EXISTS | POSIX_SEMANTICS
    info.name_length = len(encoded)
    ctypes.memmove(ctypes.addressof(buffer) + _RenameInfo.name.offset, encoded, len(encoded))
    function = ctypes.WinDLL('kernel32', use_last_error=True).SetFileInformationByHandle
    function.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    function.restype = wintypes.BOOL
    if not function(int(handle), 22, buffer, size):  # FileRenameInfoEx
        raise ctypes.WinError(ctypes.get_last_error())


def _write_private_handle(handle, data):
    for offset in range(0, len(data), 1024 * 1024):
        chunk = data[offset:offset + 1024 * 1024]
        if win32file.WriteFile(handle, chunk)[1] != len(chunk):
            raise OSError('Private storage write was incomplete.')
    win32file.FlushFileBuffers(handle)


def _create_private_handle(path):
    if win32api.GetVolumeInformation(path.anchor)[-1] != 'NTFS':
        raise UnsafeStorage('Private wallet storage requires a local NTFS volume.')
    try:
        handle = win32file.CreateFile(str(path),
            win32con.GENERIC_READ | win32con.GENERIC_WRITE | win32con.READ_CONTROL | win32con.DELETE,
            win32con.FILE_SHARE_READ | win32con.FILE_SHARE_WRITE, private_attributes(), win32con.CREATE_NEW,
            win32file.FILE_FLAG_OPEN_REPARSE_POINT | win32file.FILE_FLAG_WRITE_THROUGH, None)
    except pywintypes.error as error:
        if error.winerror in (80, 183):
            raise FileExistsError('Private storage already exists.') from None
        raise
    try:
        validate_handle(handle, directory=False)
        return handle
    except BaseException:
        handle.Close()
        raise


def create_private_file(path, data):
    """Create once with explicit owner/ACLs; preserve partial state on failure."""
    path = local_path(path)
    with ancestors(path):
        private_directory(path.parent)
        handle = _create_private_handle(path)
        try:
            _write_private_handle(handle, data)
        finally:
            handle.Close()


def atomic_write_private(path, data):
    """Replace checked private bytes through a still-open native file handle.

    Flush errors propagate, including after replacement: callers must reconcile
    the saved state instead of assuming a failed request left the old contents.
    """
    path = local_path(path)
    with ancestors(path), ExitStack() as storage:
        private_directory(path.parent)
        try:
            storage.enter_context(read_private_file(path))
        except FileNotFoundError:
            pass
        temporary = path.with_name('.paperclip-' + secrets.token_hex(16) + '.tmp')
        handle = _create_private_handle(temporary)
        replaced = False
        try:
            _write_private_handle(handle, data)
            _rename_private_handle(handle, path)
            replaced = True
            win32file.FlushFileBuffers(handle)
        finally:
            handle.Close()
            if not replaced:
                temporary.unlink()


@contextmanager
def read_private_file(path):
    """Validate the native handle before exposing a binary Python file object."""
    path = local_path(path)
    with ancestors(path):
        try:
            handle = win32file.CreateFile(str(path), win32con.GENERIC_READ | win32con.READ_CONTROL,
                win32con.FILE_SHARE_READ | win32con.FILE_SHARE_WRITE | win32con.FILE_SHARE_DELETE,
                None, win32con.OPEN_EXISTING, win32file.FILE_FLAG_OPEN_REPARSE_POINT, None)
        except pywintypes.error as error:
            if error.winerror in (2, 3):
                raise FileNotFoundError('Private metadata is not available yet.') from None
            raise
        try:
            validate_handle(handle, directory=False)
            native = handle.Detach()
            handle = None
            try:
                fd = msvcrt.open_osfhandle(native, os.O_RDONLY | os.O_BINARY)
            except BaseException:
                win32api.CloseHandle(native)
                raise
            with os.fdopen(fd, 'rb') as file:
                yield file
        finally:
            if handle is not None:
                handle.Close()


class SessionRecord:
    """Write-through recovery state, held against replacement for its lifetime.

    Keep a closed record instead of depending on directory-fsync/unlink behavior
    that Windows does not provide. An interrupted or malformed write fails closed.
    This public marker never authorizes a payment or replaces its durable journal.
    """
    ACTIVE = b'paperclip-session-active-v1\n'
    CLOSED = b'paperclip-session-closed-v1\n'

    def __init__(self, path):
        path = local_path(path)
        if win32api.GetVolumeInformation(path.anchor)[-1] != 'NTFS':
            raise UnsafeStorage('Desktop recovery records require local NTFS storage.')
        self.resources = ExitStack()
        self.started = False
        try:
            self.resources.enter_context(ancestors(path))
            try:
                self.handle = self._open(path, win32con.CREATE_NEW)
                self.created = True
            except pywintypes.error as error:
                if error.winerror != 80:
                    raise
                self.handle = self._open(path, win32con.OPEN_EXISTING)
                self.created = False
            self.resources.callback(self.handle.Close)
            validate_handle(self.handle, directory=False)
        except BaseException:
            self.resources.close()
            raise

    def _open(self, path, disposition):
        return win32file.CreateFile(str(path), win32con.GENERIC_READ | win32con.GENERIC_WRITE | win32con.READ_CONTROL,
            win32con.FILE_SHARE_READ, private_attributes(), disposition,
            win32file.FILE_FLAG_OPEN_REPARSE_POINT | win32con.FILE_FLAG_WRITE_THROUGH, None)

    def _read(self):
        win32file.SetFilePointer(self.handle, 0, win32con.FILE_BEGIN)
        return win32file.ReadFile(self.handle, 64)[1]

    def _write(self, value):
        win32file.SetFilePointer(self.handle, 0, win32con.FILE_BEGIN)
        status, count = win32file.WriteFile(self.handle, value)
        if status != 0 or count != len(value):
            raise UnsafeStorage('The desktop recovery record could not be written completely.')
        win32file.SetEndOfFile(self.handle)
        win32file.FlushFileBuffers(self.handle)

    def begin(self):
        if self.started:
            raise UnsafeStorage('This recovery record is already active.')
        previous = self._read()
        if (self.created and previous != b'') or (not self.created and previous not in (self.ACTIVE, self.CLOSED)):
            raise UnsafeStorage('The desktop recovery record needs attention.')
        self._write(self.ACTIVE)
        self.started = True
        return previous == self.ACTIVE

    def finish(self):
        if not self.started or self._read() != self.ACTIVE:
            raise UnsafeStorage('The desktop recovery record changed unexpectedly.')
        self._write(self.CLOSED)
        self.started = False

    def close(self):
        self.resources.close()
