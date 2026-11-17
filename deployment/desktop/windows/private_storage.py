"""Windows storage prerequisite; not yet connected to the desktop launcher.

Existing storage is verified, never repaired by changing its permissions. Handles
keep ancestor directories from being renamed during creation and lock acquisition.
Only local paths, current-user ownership and user/SYSTEM access are accepted.
"""
from contextlib import contextmanager
from pathlib import Path

import ntsecuritycon
import pywintypes
import win32api
import win32con
import win32file
import win32security


class UnsafeStorage(ValueError):
    pass


def user_sid():
    token = win32security.OpenProcessToken(win32api.GetCurrentProcess(), win32con.TOKEN_QUERY)
    try:
        return win32security.GetTokenInformation(token, win32security.TokenUser)[0]
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
    return path


@contextmanager
def ancestors(path):
    handles = []
    try:
        for parent in reversed(path.parents):
            handle = win32file.CreateFile(str(parent), win32con.READ_CONTROL | ntsecuritycon.FILE_READ_ATTRIBUTES,
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
def exclusive_file(path):
    path = local_path(path)
    with ancestors(path):
        handle = win32file.CreateFile(str(path), win32con.GENERIC_READ | win32con.GENERIC_WRITE | win32con.READ_CONTROL,
            win32con.FILE_SHARE_READ | win32con.FILE_SHARE_WRITE, private_attributes(), win32con.OPEN_ALWAYS,
            win32file.FILE_FLAG_OPEN_REPARSE_POINT, None)
        try:
            validate_handle(handle, directory=False)
            overlap = pywintypes.OVERLAPPED()
            win32file.LockFileEx(handle, win32con.LOCKFILE_EXCLUSIVE_LOCK | win32con.LOCKFILE_FAIL_IMMEDIATELY, 1, 0, overlap)
            yield handle
        finally:
            # Closing the handle releases the kernel lock, including after a crash.
            handle.Close()
