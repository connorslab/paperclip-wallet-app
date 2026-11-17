"""Package an unsigned Linux development preview with bundled or development Python/Tk."""
import argparse
from pathlib import Path
import shlex
import shutil
import sys
import tempfile


def build(binary, python, output, jam_python=None, helper=None):
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
        if helper is not None:
            if not (helper / 'PaperclipLauncher').is_file():
                raise RuntimeError('Missing frozen Linux launcher.')
            if any(p.is_symlink() and not p.resolve().is_relative_to(helper.resolve()) for p in helper.rglob('*')):
                raise RuntimeError('Helper link escapes the bundled runtime.')
            shutil.copytree(helper, package / 'lib' / 'PaperclipLauncher', symlinks=True)
        elif python is None:
            raise RuntimeError('Supply a frozen helper or development Python.')
        invocation = ('"$bundle/lib/PaperclipLauncher/PaperclipLauncher" ' if helper is not None
                      else shlex.quote(str(python)) + ' -I -B "$bundle/lib/launcher.py" ')
        launcher = package / 'bin' / 'paperclip-preview'
        launcher.write_text('#!/bin/sh\nset -eu\n'
                            'bundle=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)\n'
                            'exec ' + invocation +
                            '--binary "$bundle/bin/paperclip-walletd" ' + jam_arguments + '"$@"\n')
        launcher.chmod(0o755)
        (package / 'PREVIEW.txt').write_text('Development preview: unsigned. '
            'Bundled Jam/Tor, signed installation and upgrades remain release gates.\n')
        package.rename(output)
    print('Built unsigned Linux development preview; signed installation remains required.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--python', type=Path)
    parser.add_argument('--helper', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--jam-python', type=Path)
    args = parser.parse_args()
    if args.python and args.helper:
        parser.error('Choose a frozen launcher or development Python')
    build(args.binary.resolve(strict=True), args.python.resolve(strict=True) if args.python else None, args.output.absolute(), args.jam_python.absolute() if args.jam_python else None, args.helper.resolve(strict=True) if args.helper else None)
