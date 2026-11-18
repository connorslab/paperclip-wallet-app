"""Freeze the Linux launcher and a separate QA runner with Python and Tk included."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import subprocess
import sys


def build(output, work):
    if not sys.platform.startswith('linux'):
        raise RuntimeError('Build with the native Linux toolchain.')
    import PyInstaller
    import tkinter
    if PyInstaller.__version__ != '6.22.3':
        raise RuntimeError('Use the reviewed PyInstaller 6.22.3 toolchain.')
    if output.exists() or work.exists():
        raise RuntimeError('Choose fresh output and work directories.')
    output.mkdir(parents=True); work.mkdir(parents=True)
    source = Path(__file__).resolve().parent
    inputs = [source / 'launcher.py', source / 'test_launcher_ui.py', Path(__file__).resolve(),
              source.parent / 'managed_daemon.py', source.parent / 'managed_jam.py', source.parent / 'managed_tor.py', source.parent / 'tor_runtime.py', source.parent / 'pipe_io.py',
              source.parent / 'windows/private_storage.py']
    fingerprints = {str(path.relative_to(source.parent)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    provenance = {'format':1, 'python':sys.version, 'pyinstaller':PyInstaller.__version__,
        'git_revision':subprocess.run(['git', '-C', str(source), 'rev-parse', 'HEAD'], check=True, capture_output=True, text=True).stdout.strip(),
        'source_files':fingerprints,
        'packages':{item.metadata['Name']:item.version for item in importlib.metadata.distributions() if item.metadata['Name']}}
    for name, script in [('PaperclipLauncher', 'launcher.py'), ('PaperclipLauncherQA', 'test_launcher_ui.py')]:
        subprocess.run([sys.executable, '-m', 'PyInstaller', '--noconfirm', '--onedir',
            '--name', name, '--distpath', str(output), '--workpath', str(work / 'objects'),
            '--specpath', str(work), '--paths', str(source.parent), '--paths', str(source),
            '--hidden-import', 'managed_jam', '--hidden-import', 'launcher', str(source / script)], check=True)
        if fingerprints != {str(path.relative_to(source.parent)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}:
            raise RuntimeError('Source changed during the build; do not use this runtime.')
        (output / name / 'build-inputs.json').write_text(json.dumps(provenance, indent=2, sort_keys=True) + '\n')
    print('Built frozen Linux launcher and separate QA runner; no release signature added.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    build(args.output.absolute(), args.work.absolute())
