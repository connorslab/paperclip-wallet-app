"""Package an unsigned Linux development preview with an explicit external Python/Tk runtime."""
import argparse
from pathlib import Path
import shlex
import shutil
import sys
import tempfile


def build(binary, python, output, jam_python=None):
    if not sys.platform.startswith('linux'):
        raise RuntimeError('Build this development preview on Linux.')
    if output.exists() or output.is_symlink():
        raise RuntimeError('Choose a new output directory; existing packages are never overwritten.')
    source = Path(__file__).resolve().parent
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.paperclip-linux-preview-', dir=output.parent) as temporary:
        package = Path(temporary) / output.name
        (package / 'bin').mkdir(parents=True)
        (package / 'lib').mkdir()
        shutil.copy2(binary, package / 'bin' / 'paperclip-walletd')
        shutil.copy2(source / 'launcher.py', package / 'lib' / 'launcher.py')
        shutil.copy2(source.parent / 'managed_daemon.py', package / 'lib' / 'managed_daemon.py')
        shutil.copy2(source.parent / 'managed_jam.py', package / 'lib' / 'managed_jam.py')
        jam_arguments = ''
        if jam_python is not None:
            if not jam_python.is_file():
                raise RuntimeError('Supply the pinned Jars runtime interpreter.')
            jam = package / 'lib' / 'jam-runtime'; jam.mkdir()
            shutil.copy2(source.parent.parent / 'jam' / 'desktop-entry.py', jam)
            shutil.copytree(source.parent.parent / 'jam' / 'paperclip_jam', jam / 'paperclip_jam', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
            jam_arguments = '--jam-python ' + shlex.quote(str(jam_python)) + ' --jam-entry "$bundle/lib/jam-runtime/desktop-entry.py" '
        launcher = package / 'bin' / 'paperclip-preview'
        launcher.write_text('#!/bin/sh\nset -eu\n'
                            'bundle=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)\n'
                            'exec ' + shlex.quote(str(python)) + ' -I -B "$bundle/lib/launcher.py" '
                            '--binary "$bundle/bin/paperclip-walletd" ' + jam_arguments + '"$@"\n')
        launcher.chmod(0o755)
        (package / 'PREVIEW.txt').write_text('Development preview: unsigned, external Python/Tk runtime required. '
            'Bundled Jam/Tor, signed installation and upgrades remain release gates.\n')
        package.rename(output)
    print('Built unsigned Linux development preview; runtime bundling and signed installation remain required.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--python', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--jam-python', type=Path)
    args = parser.parse_args()
    build(args.binary.resolve(strict=True), args.python.resolve(strict=True), args.output.absolute(), args.jam_python.absolute() if args.jam_python else None)
