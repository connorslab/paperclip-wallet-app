"""Freeze the explicitly supplied reviewed Linux Jars environment for packaging."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import shutil
import subprocess
import sys
import sysconfig


def build(source, secp, license_file, output, work):
    if not sys.platform.startswith('linux'):
        raise RuntimeError('Build with the native Linux toolchain.')
    import PyInstaller
    if PyInstaller.__version__ != '6.22.3':
        raise RuntimeError('Use the reviewed PyInstaller 6.22.3 toolchain.')
    if output.exists() or output.is_symlink() or work.exists():
        raise RuntimeError('Choose fresh output and work directories.')
    python_license = Path(sysconfig.get_path('stdlib')) / 'LICENSE.txt'
    if not python_license.is_file() or not license_file.is_file():
        raise RuntimeError('Supply the Python and secp256k1 license notices.')
    inputs = [Path(__file__).resolve(), source / 'jam/desktop-entry.py']
    inputs += [source / 'jam/rpc_batch.py', source / 'jam/paperclip_jam/vendor/LICENSE', source / 'jam/paperclip_jam/vendor/README.txt']
    inputs += sorted((source / 'jam/paperclip_jam').rglob('*.py'))
    fingerprints = {str(path.relative_to(source)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    revision = subprocess.run(['git', '-C', str(source), 'rev-parse', 'HEAD'], check=True, capture_output=True, text=True).stdout.strip()
    output.mkdir(parents=True); work.mkdir(parents=True)
    bundled_secp = work / 'libsecp256k1.so'
    shutil.copy2(secp, bundled_secp)
    shutil.copy2(license_file, work / 'libsecp256k1-COPYING')
    packages = ['jmcore', 'jmwallet', 'jmwalletd', 'maker', 'taker', 'tumbler', 'orderbook_watcher', 'paperclip_jam']
    spec = work / 'PaperclipJars.spec'
    spec.write_text('''from PyInstaller.utils.hooks import collect_all
datas, binaries, hidden = ''' + repr([(str(python_license), 'licenses/python'), (str(work / 'libsecp256k1-COPYING'), 'licenses/secp256k1')]) + ''', [], []
for package in ''' + repr(packages) + ''':
    data, binary, imports = collect_all(package)
    datas += data; binaries += binary; hidden += imports
binaries.append((''' + repr(str(bundled_secp)) + ''', '.'))
a = Analysis([''' + repr(str(source / 'jam/desktop-entry.py')) + '''], pathex=[''' + repr(str(source / 'jam')) + '''],
    binaries=binaries, datas=datas, hiddenimports=hidden, hookspath=[], runtime_hooks=[], excludes=[])
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name='PaperclipJars',
    debug=False, bootloader_ignore_signals=False, strip=False, upx=False, console=True)
collection = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name='PaperclipJars')
''')
    subprocess.run([sys.executable, '-m', 'PyInstaller', '--noconfirm', '--distpath', str(output),
                    '--workpath', str(work / 'objects'), str(spec)], check=True)
    if fingerprints != {str(path.relative_to(source)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}:
        raise RuntimeError('Source changed during the build; do not use this runtime.')
    (output / 'PaperclipJars/build-inputs.json').write_text(json.dumps({'format':1,
        'python':sys.version, 'pyinstaller':PyInstaller.__version__, 'git_revision':revision,
        'source_files':fingerprints, 'secp256k1_sha256':hashlib.sha256(bundled_secp.read_bytes()).hexdigest(),
        'packages':{item.metadata['Name']:item.version for item in importlib.metadata.distributions() if item.metadata['Name']}}, indent=2, sort_keys=True) + '\n')
    print('Built the Linux Jars runtime; no release signature added.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--secp256k1', required=True, type=Path)
    parser.add_argument('--secp256k1-license', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--work', required=True, type=Path)
    args = parser.parse_args()
    build(args.source.resolve(strict=True), args.secp256k1.resolve(strict=True), args.secp256k1_license.resolve(strict=True), args.output.absolute(), args.work.absolute())
