"""Validate an explicitly reviewed Tor distribution before packaging or startup.

The inventory detects damaged/incomplete packages; it is not a publisher trust
anchor. Release signatures and the review of the supplied runtime remain required.
No executable is downloaded or selected from the user's PATH.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import sys


def target():
    architecture = platform.machine().lower()
    architecture = {'amd64':'x86_64', 'aarch64':'arm64'}.get(architecture, architecture)
    system = {'darwin':'macos', 'win32':'windows'}.get(sys.platform, sys.platform)
    return system + '-' + architecture


def relative_file(value):
    if not isinstance(value, str) or len(value) > 240:
        raise ValueError('Invalid Tor runtime file name.')
    parts = value.split('/')
    for part in parts:
        if (not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]*', part)
                or part.endswith('.') or part.split('.')[0].upper() in
                {'CON', 'PRN', 'AUX', 'NUL', *('COM' + str(i) for i in range(10)), *('LPT' + str(i) for i in range(10))}):
            raise ValueError('Invalid Tor runtime file name.')
    return value


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def validate(root):
    root = Path(root).absolute()
    paths = [root, *root.rglob('*')]
    for path in paths:
        mode = path.lstat().st_mode
        if (path.is_symlink() or getattr(path, 'is_junction', lambda: False)()
                or not (stat.S_ISREG(mode) or stat.S_ISDIR(mode))):
            raise ValueError('Tor runtime contains unsupported linked or special files.')
    with (root / 'runtime.json').open('rb') as file:
        encoded = file.read(131073)
    if len(encoded) > 131072:
        raise ValueError('Tor runtime inventory is too large.')
    metadata = json.loads(encoded)
    if (not isinstance(metadata, dict) or set(metadata) != {'format', 'target', 'version', 'source', 'executable', 'licenses', 'files'}
            or type(metadata['format']) is not int or metadata['format'] != 1
            or metadata['target'] != target()
            or not isinstance(metadata['version'], str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){3}', metadata['version'])
            or not isinstance(metadata['source'], str) or not metadata['source'].startswith('https://') or len(metadata['source']) > 2048
            or not isinstance(metadata['files'], dict) or not 1 <= len(metadata['files']) <= 256
            or not isinstance(metadata['licenses'], list) or not metadata['licenses']):
        raise ValueError('Incompatible or incomplete Tor runtime inventory.')
    executable = relative_file(metadata['executable'])
    for name, expected in metadata['files'].items():
        relative_file(name)
        if not isinstance(expected, str) or not re.fullmatch(r'[a-f0-9]{64}', expected):
            raise ValueError('Invalid Tor runtime fingerprint.')
    licenses = [relative_file(name) for name in metadata['licenses']]
    actual = {str(path.relative_to(root)).replace('\\', '/') for path in paths if path.is_file()} - {'runtime.json'}
    if (actual != set(metadata['files']) or executable not in actual
            or any(name not in actual or name == executable for name in licenses)):
        raise ValueError('Tor runtime is missing files or contains unrecorded files.')
    for name, expected in metadata['files'].items():
        if digest(root / name) != expected:
            raise ValueError('Tor runtime does not match its recorded fingerprints.')
    if os.name != 'nt' and not os.access(root / executable, os.X_OK):
        raise ValueError('Tor runtime is not executable.')
    return root / executable, metadata


def copy_runtime(source, destination):
    _, metadata = validate(source)
    shutil.copytree(source, destination)
    # Detect a changed source or incomplete copy before the outer app is sealed.
    _, copied = validate(destination)
    if copied != metadata:
        raise ValueError('Tor runtime changed during packaging.')
    return metadata
