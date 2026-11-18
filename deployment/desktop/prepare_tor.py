"""Prepare one pinned, previously signature-verified native Tor expert archive.

No download, network activation or installation. Archive hashes are reviewed in
source control. The input archive is preserved; macOS development signing is an
explicit transformation of the extracted copy, before its inventory is recorded.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

from tor_runtime import digest, relative_file, target, validate

MAX_ARCHIVE = 128 * 1024 * 1024
MAX_EXPANDED = 512 * 1024 * 1024
MAX_MEMBERS = 256


def file_digest(file):
    file.seek(0)
    result = hashlib.sha256()
    for block in iter(lambda: file.read(1024 * 1024), b''):
        result.update(block)
    return result.hexdigest()


def unpack(file, output):
    """Write only bounded ordinary files into a new, empty staging directory."""
    names, size = set(), 0
    file.seek(0)
    with tarfile.open(fileobj=file, mode='r:gz') as archive:
        for member in archive:
            name = relative_file(member.name)
            if (name.casefold() in names or len(names) >= MAX_MEMBERS
                    or not (member.isfile() or member.isdir()) or member.size < 0):
                raise ValueError('Unsupported Tor archive entry.')
            names.add(name.casefold())
            size += member.size
            if size > MAX_EXPANDED or member.size > MAX_ARCHIVE:
                raise ValueError('Tor archive exceeds its extraction bounds.')
            destination = output / name
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, destination.open('xb') as sink:
                    shutil.copyfileobj(source, sink, length=1024 * 1024)
                if destination.stat().st_size != member.size:
                    raise ValueError('Tor archive contains a truncated file.')
                destination.chmod(0o755 if member.mode & 0o111 else 0o644)


def prepare(archive, output, record, *, ad_hoc_sign=False):
    archive, output = Path(archive).absolute(), Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError('Choose a new output directory; existing runtimes are preserved.')
    if sys.platform == 'darwin' and not ad_hoc_sign:
        raise ValueError('macOS development preparation requires explicit --ad-hoc-sign.')
    if sys.platform != 'darwin' and ad_hoc_sign:
        raise ValueError('Use native Apple tools for macOS signing.')
    if not stat.S_ISREG(archive.lstat().st_mode) or archive.stat().st_size > MAX_ARCHIVE:
        raise ValueError('Supply the bounded ordinary archive file.')
    output.parent.mkdir(parents=True, exist_ok=True)
    with archive.open('rb') as file:
        if file_digest(file) != record['sha256']:
            raise ValueError('Tor archive does not match the reviewed release hash.')
        with tempfile.TemporaryDirectory(prefix='.paperclip-tor-', dir=output.parent) as temporary:
            staged = Path(temporary) / 'runtime'
            staged.mkdir()
            unpack(file, staged)
            if file_digest(file) != record['sha256']:
                raise ValueError('Tor archive changed during preparation.')
            executable = relative_file(record['executable'])
            if not (staged / executable).is_file():
                raise ValueError('Tor executable is missing from the reviewed archive.')
            licenses = sorted(str(path.relative_to(staged)).replace('\\', '/') for path in (staged / 'docs').glob('*.txt'))
            if not {'docs/tor.txt', 'docs/libevent.txt', 'docs/openssl.txt'}.issubset(licenses):
                raise ValueError('Tor archive is missing required license notices.')
            if ad_hoc_sign:
                # Sign only Mach-O files, never shell scripts or license text.
                # The original signed upstream archive is never modified.
                for path in sorted(staged.rglob('*')):
                    if path.is_file():
                        with path.open('rb') as code:
                            magic = code.read(4)
                        if magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
                            subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True)
                            subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True)
            metadata = {'format':1, 'target':target(), 'version':record['version'],
                'source':record['source'], 'executable':executable, 'licenses':licenses,
                'files':{str(path.relative_to(staged)).replace('\\', '/'):digest(path)
                         for path in sorted(staged.rglob('*')) if path.is_file()}}
            (staged / 'runtime.json').write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')
            validate(staged)
            staged.rename(output)
    return metadata


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ad-hoc-sign', action='store_true')
    args = parser.parse_args()
    inventory = json.loads(Path(__file__).with_name('tor-artifacts.json').read_text())
    if target() not in inventory['targets']:
        parser.error('No reviewed Tor archive is recorded for this native target')
    prepare(args.archive, args.output, inventory['targets'][target()], ad_hoc_sign=args.ad_hoc_sign)
    print('Prepared the pinned Tor runtime. No wallet, node or Tor connection was started.')
