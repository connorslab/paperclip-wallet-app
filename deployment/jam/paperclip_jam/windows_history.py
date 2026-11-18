"""Native private history I/O; upstream CSV and outcome semantics are retained."""
from contextlib import contextmanager
import csv
from dataclasses import fields
import io
import msvcrt
import os

import win32api
import win32con

from windows import private_storage as native
from paperclip_jam.windows_storage import atomic_write_private, ensure_private_directory


def open_history_file(path, flags):
    if flags == os.O_RDONLY:
        with native.read_private_file(path) as reader:
            return os.dup(reader.fileno())
    if flags != os.O_WRONLY | os.O_CREAT | os.O_APPEND:
        raise ValueError('Unsupported history file access')
    with native.writable_private_file(path) as handle:
        process = win32api.GetCurrentProcess()
        duplicate = win32api.DuplicateHandle(process, handle, process, 0, False, win32con.DUPLICATE_SAME_ACCESS)
        raw = duplicate.Detach()
        try:
            return msvcrt.open_osfhandle(raw, os.O_WRONLY | os.O_APPEND | os.O_BINARY)
        except BaseException:
            win32api.CloseHandle(raw)
            raise


def install(namespace):
    original_path = namespace['_get_history_path']
    @contextmanager
    def history_lock(history_path, *, shared=False):
        # As in upstream Windows, readers take exclusive ownership too.
        ensure_private_directory(history_path.parent)
        with native.exclusive_file(namespace['_history_lock_path'](history_path), nonblocking=False):
            yield

    def history_path(data_dir=None):
        if data_dir is None:
            data_dir = namespace['get_default_data_dir']()
        ensure_private_directory(data_dir)
        return original_path(data_dir)

    def open_file(path, flags):
        try:
            return open_history_file(path, flags)
        except (OSError, ValueError) as error:
            raise namespace['HistoryWriteError']('Could not securely open wallet history') from error

    def write_entries(entries, history_path):
        try:
            output = io.StringIO(newline='')
            writer = csv.DictWriter(output, fieldnames=namespace['_get_fieldnames']())
            writer.writeheader()
            for entry in sorted(entries, key=lambda item: item.timestamp):
                writer.writerow({field.name:getattr(entry,field.name) for field in fields(entry)})
            atomic_write_private(history_path,output.getvalue().encode('utf-8'))
            return True
        except Exception:
            namespace['logger'].error('Could not persist wallet history; existing data was not permission-repaired')
            return False

    namespace.update(_get_history_path=history_path, _history_lock=history_lock,
        _open_owner_only_regular=open_file, _write_history_entries_atomic=write_entries)
