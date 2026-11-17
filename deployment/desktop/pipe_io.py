"""Bounded reads from a single-reader owned subprocess pipe.

None means the deadline elapsed; empty bytes means EOF. Never read a whole line:
an incomplete child message must not block startup, shutdown or health checks.
"""
import math
import os
import select
import time

if os.name == 'nt':
    import ctypes
    from ctypes import wintypes
    import msvcrt

    _kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    _peek = _kernel.PeekNamedPipe
    _peek.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
                      ctypes.POINTER(wintypes.DWORD), ctypes.POINTER(wintypes.DWORD),
                      ctypes.POINTER(wintypes.DWORD)]
    _peek.restype = wintypes.BOOL
    _type = _kernel.GetFileType
    _type.argtypes = [wintypes.HANDLE]
    _type.restype = wintypes.DWORD


def read_available(fd, limit, timeout):
    if not isinstance(limit, int) or not 1 <= limit <= 65536 or not math.isfinite(timeout) or timeout < 0:
        raise ValueError('Invalid bounded pipe read')
    if os.name != 'nt':
        return os.read(fd, limit) if select.select([fd], [], [], timeout)[0] else None
    # Windows select accepts sockets, not subprocess pipes. Peek without
    # consuming bytes, then read only the available amount. The caller is the
    # sole reader: no other thread may issue a blocking read on this handle.
    handle = msvcrt.get_osfhandle(fd)
    if _type(handle) != 3:  # FILE_TYPE_PIPE
        raise ValueError('Expected an owned subprocess pipe')
    # Text-mode CRT reads may look ahead after a lone CR or treat Ctrl-Z as
    # EOF. The protocol is bytes, so neither translation is permitted.
    msvcrt.setmode(fd, os.O_BINARY)
    deadline = time.monotonic() + timeout
    while True:
        available = wintypes.DWORD()
        if not _peek(handle, None, 0, None, ctypes.byref(available), None):
            error = ctypes.get_last_error()
            if error in (109, 232, 233):  # broken, closing or disconnected pipe
                return b''
            raise ctypes.WinError(error)
        if available.value:
            return os.read(fd, min(limit, available.value))
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        time.sleep(min(0.01, remaining))
