"""Freeze an unsigned Windows preview and separate QA runner with Python/Tk included."""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def build(binary, output, work):
    if os.name != 'nt':
        raise RuntimeError('Build with the native Windows toolchain.')
    import PyInstaller
    import tkinter
    if PyInstaller.__version__ != '6.22.3' or importlib.metadata.version('pywin32') != '311':
        raise RuntimeError('Use the reviewed PyInstaller 6.22.3 and pywin32 311 toolchain.')
    if output.exists() or work.exists():
        raise RuntimeError('Choose fresh output and work directories.')
    output.parent.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True)
    source = Path(__file__).resolve().parent
    inputs = [source / 'launcher.py', source / 'test_launcher_ui.py', source / 'test_managed_daemon.py', source / 'private_storage.py',
        Path(__file__).resolve(), source.parent / 'linux/launcher.py',
        source.parent / 'managed_daemon.py', source.parent / 'managed_jam.py', source.parent / 'pipe_io.py']
    def fingerprints():
        return {str(path.relative_to(source.parent)).replace('\\', '/'):
                hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    provenance = {'format':1, 'python':sys.version, 'pyinstaller':PyInstaller.__version__,
        'git_revision':subprocess.run(['git', '-C', str(source), 'rev-parse', 'HEAD'], check=True,
                                      capture_output=True, text=True).stdout.strip(),
        'source_files':fingerprints(),
        'packages':{item.metadata['Name']:item.version for item in importlib.metadata.distributions() if item.metadata['Name']}}
    with tempfile.TemporaryDirectory(prefix='.paperclip-windows-preview-', dir=output.parent) as temporary:
        package = Path(temporary) / output.name
        for name, script, console in [('PaperclipLauncher', 'launcher.py', '--windowed'),
                                      ('PaperclipLauncherQA', 'test_launcher_ui.py', '--console')]:
            # pywin32 imports this from native PyTime.cpp while constructing
            # GetFileInformationByHandle timestamps; static analysis cannot see it.
            subprocess.run([sys.executable, '-m', 'PyInstaller', '--noconfirm', '--onedir', console,
                '--name', name, '--distpath', str(package), '--workpath', str(work / 'objects'),
                '--specpath', str(work), '--paths', str(source.parent),
                '--hidden-import', 'windows.launcher', '--hidden-import', 'linux.launcher',
                '--hidden-import', 'win32timezone',
                str(source / script)], check=True)
        if provenance['source_files'] != fingerprints():
            raise RuntimeError('Source changed during the build; do not use this runtime.')
        copied = package / 'PaperclipLauncher/paperclip-walletd.exe'
        shutil.copy2(binary, copied)
        provenance['daemon_sha256'] = hashlib.sha256(copied.read_bytes()).hexdigest()
        provenance['daemon_version'] = subprocess.run([str(copied), '--version'], check=True,
            capture_output=True, text=True).stdout.strip()
        (package / 'build-info.json').write_text(json.dumps(provenance, indent=2, sort_keys=True) + '\n')
        (package / 'PREVIEW.txt').write_text('Unsigned development preview. PaperclipLauncherQA is test tooling, not part of installation.\n'
            'Bundled Windows Jars, Tor/RPC configuration, signing and installed upgrades require separate acceptance.\n')
        package.rename(output)
    print('Built unsigned native Windows preview and separate QA runner.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--work', required=True, type=Path)
    args = parser.parse_args()
    build(args.binary.resolve(strict=True), args.output.absolute(), args.work.absolute())
