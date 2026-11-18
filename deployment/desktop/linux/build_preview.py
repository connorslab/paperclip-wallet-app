"""Package an unsigned Linux development preview with bundled or development Python/Tk."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from tor_runtime import copy_runtime as copy_tor_runtime


def copy_runtime(helper, destination, executable):
    inputs = json.loads((helper / 'build-inputs.json').read_text())
    if inputs.get('format') != 1 or not inputs.get('source_files'):
        raise RuntimeError('Rebuild the helper with source fingerprints before packaging.')
    if not (helper / executable).is_file():
        raise RuntimeError('Missing frozen Linux executable.')
    if any(p.is_symlink() and not p.resolve().is_relative_to(helper.resolve()) for p in helper.rglob('*')):
        raise RuntimeError('Helper link escapes the bundled runtime.')
    shutil.copytree(helper, destination, symlinks=True)
    return inputs


def build(binary, python, output, jam_python=None, helper=None, jam_helper=None, tor_runtime=None):
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
        shutil.copy2(source.parent / 'node_setup_client.py', package / 'lib' / 'node_setup_client.py')
        shutil.copy2(source.parent / 'managed_tor.py', package / 'lib' / 'managed_tor.py')
        shutil.copy2(source.parent / 'tor_runtime.py', package / 'lib' / 'tor_runtime.py')
        shutil.copy2(source.parent / 'pipe_io.py', package / 'lib' / 'pipe_io.py')
        provenance = {'format':1, 'builder_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'daemon_sha256':hashlib.sha256((package / 'bin/paperclip-walletd').read_bytes()).hexdigest(),
            'daemon_version':subprocess.run([str(package / 'bin/paperclip-walletd'), '--version'], check=True, capture_output=True, text=True).stdout.strip()}
        jam_arguments = ''
        if jam_helper is not None:
            if jam_python is not None:
                raise RuntimeError('Choose bundled Jars or a development interpreter.')
            provenance['jars'] = copy_runtime(jam_helper, package / 'lib/PaperclipJars', 'PaperclipJars')
            jam_arguments = '--jam-executable "$bundle/lib/PaperclipJars/PaperclipJars" '
        elif jam_python is not None:
            if not jam_python.is_file():
                raise RuntimeError('Supply the pinned Jars runtime interpreter.')
            jam = package / 'lib' / 'jam-runtime'; jam.mkdir()
            shutil.copy2(source.parent.parent / 'jam' / 'desktop-entry.py', jam)
            shutil.copy2(source.parent.parent / 'jam' / 'rpc_batch.py', jam)
            shutil.copytree(source.parent.parent / 'jam' / 'paperclip_jam', jam / 'paperclip_jam', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
            jam_arguments = '--jam-python ' + shlex.quote(str(jam_python)) + ' --jam-entry "$bundle/lib/jam-runtime/desktop-entry.py" '
        if tor_runtime is not None:
            if not jam_arguments:
                raise RuntimeError('The owned Tor runtime requires bundled Jars.')
            provenance['tor'] = copy_tor_runtime(tor_runtime, package / 'lib/PaperclipTor')
            jam_arguments += '--tor-runtime "$bundle/lib/PaperclipTor" '
        if helper is not None:
            provenance['helper'] = copy_runtime(helper, package / 'lib/PaperclipLauncher', 'PaperclipLauncher')
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
            'Tor/RPC configuration, signed installation and upgrades require separate acceptance.\n')
        (package / 'build-info.json').write_text(json.dumps(provenance, indent=2, sort_keys=True) + '\n')
        package.rename(output)
    print('Built unsigned Linux development preview; signed installation remains required.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--python', type=Path)
    parser.add_argument('--helper', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--jam-python', type=Path)
    parser.add_argument('--jam-helper', type=Path)
    parser.add_argument('--tor-runtime', type=Path)
    args = parser.parse_args()
    if args.python and args.helper:
        parser.error('Choose a frozen launcher or development Python')
    if args.jam_python and args.jam_helper:
        parser.error('Choose bundled Jars or a development interpreter')
    build(args.binary.resolve(strict=True), args.python.resolve(strict=True) if args.python else None, args.output.absolute(), args.jam_python.absolute() if args.jam_python else None, args.helper.resolve(strict=True) if args.helper else None, args.jam_helper.resolve(strict=True) if args.jam_helper else None, args.tor_runtime.absolute() if args.tor_runtime else None)
