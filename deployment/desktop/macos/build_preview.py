"""Build a development-only Mac launcher with native Apple tools.

The preview uses bundled helpers or explicitly selected development interpreters.
It is not a Developer ID release or notarized distribution candidate.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile


def build(binary, python, output, jam_python=None, helpers=None):
    if sys.platform != 'darwin':
        raise RuntimeError('Build this preview with native Apple tools on macOS.')
    if output.exists() or output.is_symlink():
        raise RuntimeError('Choose a new output path; existing apps are never overwritten.')
    if output.suffix != '.app':
        raise RuntimeError('The development preview output must end in .app.')
    source = Path(__file__).resolve().parent
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.paperclip-preview-', dir=output.parent) as temporary:
        app = Path(temporary) / output.name
        contents = app / 'Contents'
        executable = contents / 'MacOS'
        resources = contents / 'Resources'
        executable.mkdir(parents=True)
        resources.mkdir()
        architecture = platform.machine()
        if architecture not in ('arm64', 'x86_64'):
            raise RuntimeError('Unsupported native Mac architecture.')
        swift_source = Path(temporary) / 'Launcher.swift'
        shutil.copy2(source / 'Launcher.swift', swift_source)
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-target', architecture + '-apple-macosx13.0',
            '-framework', 'AppKit', str(swift_source), '-o', str(executable / 'PaperclipLauncher')], check=True)
        shutil.copy2(binary, executable / 'paperclip-walletd')
        for name in ('launcher_entry.py', 'launcher_bridge.py', 'managed_daemon.py', 'managed_jam.py', 'pipe_io.py'):
            shutil.copy2(source.parent / name, resources / name)
        configuration = {}
        provenance = {'format':1, 'architecture':architecture,
            'builder_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'launcher_source_sha256':hashlib.sha256(swift_source.read_bytes()).hexdigest(),
            'daemon_version':subprocess.run([str(executable / 'paperclip-walletd'), '--version'], check=True, capture_output=True, text=True).stdout.strip()}
        if helpers is not None:
            helper_inputs = json.loads((helpers / 'build-inputs.json').read_text())
            if helper_inputs.get('format') != 1 or not helper_inputs.get('source_files'):
                raise RuntimeError('Rebuild helpers with source fingerprints before packaging.')
            provenance['helpers'] = helper_inputs
            for name in ('PaperclipHelper', 'PaperclipJars'):
                bundle = helpers / (name + '.app')
                if not (bundle / 'Contents' / 'MacOS' / name).is_file():
                    raise RuntimeError('Missing bundled helper executable.')
                if any(path.is_symlink() and not path.resolve().is_relative_to(bundle.resolve()) for path in bundle.rglob('*')):
                    raise RuntimeError('Helper link points outside its bundle.')
                subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
                shutil.copytree(bundle, contents / 'Helpers' / bundle.name, symlinks=True)
            configuration['bundledHelpers'] = True
        elif python is not None:
            configuration['pythonExecutable'] = str(python)
        else:
            raise RuntimeError('Supply the built helper apps or explicit development Python.')
        if jam_python is not None:
            if not jam_python.is_file():
                raise RuntimeError('Supply the pinned Jars runtime interpreter.')
            jam = resources / 'jam-runtime'; jam.mkdir()
            shutil.copy2(source.parent.parent / 'jam' / 'desktop-entry.py', jam)
            shutil.copytree(source.parent.parent / 'jam' / 'paperclip_jam', jam / 'paperclip_jam', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
            configuration['jamPythonExecutable'] = str(jam_python)
        (resources / 'runtime.json').write_text(json.dumps(configuration))
        with (contents / 'Info.plist').open('wb') as file:
            plistlib.dump({
                'CFBundleName':'Paperclip Preview', 'CFBundleDisplayName':'Paperclip Preview',
                'CFBundleExecutable':'PaperclipLauncher', 'CFBundleIdentifier':'org.paperclip.wallet.desktop.preview',
                'CFBundlePackageType':'APPL', 'CFBundleVersion':'1', 'CFBundleShortVersionString':'0.0.0',
                'LSMinimumSystemVersion':'13.0', 'NSPrincipalClass':'NSApplication',
                'NSHighResolutionCapable':True,
            }, file)
        subprocess.run(['codesign', '--force', '--sign', '-', str(executable / 'paperclip-walletd')], check=True)
        provenance['daemon_sha256'] = hashlib.sha256((executable / 'paperclip-walletd').read_bytes()).hexdigest()
        (resources / 'build-info.json').write_text(json.dumps(provenance, indent=2, sort_keys=True) + '\n')
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        app.rename(output)
    print('Built ad-hoc signed native Mac preview; release signing and notarization remain required.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--python', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--jam-python', type=Path)
    parser.add_argument('--helpers', type=Path)
    args = parser.parse_args()
    if args.helpers and (args.python or args.jam_python):
        parser.error('Choose built helpers or development interpreters')
    build(args.binary.resolve(strict=True), args.python.resolve(strict=True) if args.python else None, args.output.absolute(), args.jam_python.absolute() if args.jam_python else None, args.helpers.resolve(strict=True) if args.helpers else None)
