"""Checked Windows implementation of the pinned upstream private-file API.

Managed desktop storage accepts local paths without aliases. Existing permissions
are validated, never repaired. Import this only through the reviewed build patch.
"""
from windows import private_storage as native


def ensure_private_directory(path):
    path = native.local_path(path)
    missing = []
    parent = path.parent
    while not parent.exists():
        missing.append(parent)
        parent = parent.parent
    for directory in reversed(missing):
        native.private_directory(directory)
    native.private_directory(path)


def ensure_private_file(path):
    with native.read_private_file(path):
        pass


def read_private_file(path):
    with native.read_private_file(path) as reader:
        return reader.read()


def atomic_write_private(path, data):
    path = native.local_path(path)
    ensure_private_directory(path.parent)
    native.atomic_write_private(path, data)


def create_private_file_exclusive(path, data):
    path = native.local_path(path)
    ensure_private_directory(path.parent)
    native.create_private_file(path, data)


# Native desktop config and metadata have the same ownership requirements as
# wallet files. Do not follow or permission-repair configured aliases on Windows.
ensure_sensitive_directory = ensure_private_directory
ensure_sensitive_file = ensure_private_file
read_sensitive_file = read_private_file
atomic_write_sensitive_file = atomic_write_private
