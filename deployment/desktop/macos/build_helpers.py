"""Build native desktop helper app bundles using pinned PyInstaller tooling.

The reviewed Jam environment and libsecp256k1 are explicit local inputs. Output is
ad-hoc signed development code; the release signing identity is not substituted.
"""
import argparse
import json
import hashlib
import importlib.metadata
import shutil
from pathlib import Path
import subprocess
import sys
import sysconfig


def build(source, secp, output, work):
    if sys.platform != 'darwin':
        raise RuntimeError('Build these helper apps with native Apple tools.')
    if output.exists() or output.is_symlink() or work.exists():
        raise RuntimeError('Choose fresh output and work directories.')
    output.mkdir(parents=True); work.mkdir(parents=True)
    import PyInstaller
    if PyInstaller.__version__ != '6.22.3':
        raise RuntimeError('Use the reviewed PyInstaller 6.22.3 toolchain.')
    inputs = [source / 'desktop' / name for name in ('launcher_entry.py', 'launcher_bridge.py', 'managed_daemon.py', 'managed_jam.py', 'managed_tor.py', 'node_setup_client.py', 'tor_runtime.py', 'pipe_io.py')]
    inputs += [source / 'jam/desktop-entry.py', source / 'desktop/windows/private_storage.py', Path(__file__).resolve()]
    inputs += [source / 'jam/rpc_batch.py', source / 'jam/paperclip_jam/vendor/LICENSE', source / 'jam/paperclip_jam/vendor/README.txt']
    inputs += sorted((source / 'jam/paperclip_jam').rglob('*.py'))
    source_hashes = {str(path.relative_to(source)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    revision = subprocess.run(['git', '-C', str(source), 'rev-parse', 'HEAD'], check=True, capture_output=True, text=True).stdout.strip()
    bundled_secp = work / 'libsecp256k1.dylib'
    shutil.copy2(secp, bundled_secp)
    license_file = secp.parent.parent / 'COPYING'
    if not license_file.is_file():
        raise RuntimeError('Supply the reviewed secp256k1 installation with its COPYING file.')
    shutil.copy2(license_file, work / 'libsecp256k1-COPYING')
    python_license = Path(sysconfig.get_path('stdlib')) / 'LICENSE.txt'
    if not python_license.is_file():
        raise RuntimeError('Missing Python license in the selected runtime.')
    packages = ['jmcore', 'jmwallet', 'jmwalletd', 'maker', 'taker', 'tumbler', 'orderbook_watcher', 'paperclip_jam']
    for name, entry in [('PaperclipHelper', source / 'desktop' / 'launcher_entry.py'),
                        ('PaperclipJars', source / 'jam' / 'desktop-entry.py')]:
        spec = work / (name + '.spec')
        spec.write_text('''from PyInstaller.utils.hooks import collect_all
packages = ''' + repr(packages if name == 'PaperclipJars' else []) + '''
datas, binaries, hidden = ''' + repr([(str(python_license), 'licenses/python')]) + ''', [], ['launcher_bridge', 'managed_daemon', 'managed_jam']
for package in packages:
    data, binary, imports = collect_all(package)
    datas += data; binaries += binary; hidden += imports
''' + ('binaries.append((' + repr(str(bundled_secp)) + ", '.'))\ndatas.append((" + repr(str(work / 'libsecp256k1-COPYING')) + ", '.'))\n" if name == 'PaperclipJars' else '') + '''
a = Analysis([''' + repr(str(entry)) + '''], pathex=[''' + repr(str(source / 'desktop')) + ',' + repr(str(source / 'jam')) + '''],
    binaries=binaries, datas=datas, hiddenimports=hidden, hookspath=[], runtime_hooks=[], excludes=[])
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name=''' + repr(name) + ''',
    debug=False, bootloader_ignore_signals=False, strip=False, upx=False, console=True,
    disable_windowed_traceback=False, codesign_identity=None)
collection = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name=''' + repr(name) + ''')
app = BUNDLE(collection, name=''' + repr(name + '.app') + ''', bundle_identifier=''' + repr('org.paperclip.wallet.preview.' + name.lower()) + ''',
    info_plist={'LSUIElement':True})
''')
        subprocess.run([sys.executable, '-m', 'PyInstaller', '--noconfirm', '--distpath', str(output),
                        '--workpath', str(work / 'objects'), str(spec)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(output / (name + '.app'))], check=True)
    if source_hashes != {str(path.relative_to(source)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}:
        raise RuntimeError('Source changed during the build; do not use these helpers.')
    (output / 'build-inputs.json').write_text(json.dumps({'format':1, 'pyinstaller':PyInstaller.__version__,
        'python':sys.version, 'git_revision':revision, 'source_files':source_hashes,
        'packages':{item.metadata['Name']:item.version for item in importlib.metadata.distributions() if item.metadata['Name']}, 'secp256k1_sha256':hashlib.sha256(secp.read_bytes()).hexdigest()}, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--secp256k1', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    build(args.source.resolve(strict=True), args.secp256k1.resolve(strict=True), args.output.absolute(), args.work.absolute())
