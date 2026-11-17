"""Freeze the Linux launcher and a separate QA runner with Python and Tk included."""
import argparse
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
    for name, script in [('PaperclipLauncher', 'launcher.py'), ('PaperclipLauncherQA', 'test_launcher_ui.py')]:
        subprocess.run([sys.executable, '-m', 'PyInstaller', '--noconfirm', '--onedir',
            '--name', name, '--distpath', str(output), '--workpath', str(work / 'objects'),
            '--specpath', str(work), '--paths', str(source.parent), '--paths', str(source),
            '--hidden-import', 'managed_jam', '--hidden-import', 'launcher', str(source / script)], check=True)
    print('Built frozen Linux launcher and separate QA runner; no release signature added.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    build(args.output.absolute(), args.work.absolute())
