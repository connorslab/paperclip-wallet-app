"""Check a relocated Mac package without access to build-host dependencies.

Uses only disposable unfunded directories. No GUI, wallet creation or payment.
The system Python drives tests; all application code runs in the bundled helpers.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from tor_runtime import validate as validate_tor_runtime


def check(app):
    source = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix='paperclip-relocation-') as temporary:
        relocated = Path(temporary).resolve() / 'Path With Spaces' / app.name
        shutil.copytree(app, relocated, symlinks=True)
        contents = relocated / 'Contents'
        configuration = json.loads((contents / 'Resources/runtime.json').read_text())
        if configuration not in ({'bundledHelpers': True}, {'bundledHelpers': True, 'bundledTor': True}):
            raise RuntimeError('This check requires bundled helpers without external interpreters.')
        executable = contents / 'MacOS/paperclip-walletd'
        provenance = json.loads((contents / 'Resources/build-info.json').read_text())
        if provenance.get('format') != 1 or provenance.get('daemon_sha256') != hashlib.sha256(executable.read_bytes()).hexdigest():
            raise RuntimeError('The packaged daemon does not match its source record.')
        if not provenance.get('helpers', {}).get('source_files'):
            raise RuntimeError('The packaged helpers have no source fingerprints.')
        tor_args, tor_runtime_args = [], []
        if configuration.get('bundledTor'):
            tor_root = contents / 'Resources/PaperclipTor'
            tor, recorded = validate_tor_runtime(tor_root)
            if provenance.get('tor') != recorded:
                raise RuntimeError('The packaged Tor does not match its source record.')
            tor_args = ['--tor', str(tor)]
            tor_runtime_args = ['--tor-runtime', str(tor_root)]
        helpers = contents / 'Helpers'
        jam = helpers / 'PaperclipJars.app/Contents/MacOS/PaperclipJars'
        helper = helpers / 'PaperclipHelper.app/Contents/MacOS/PaperclipHelper'
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(relocated)], check=True)
        profile = '(version 1)(allow default)'
        for denied in ('/opt/homebrew', '/usr/local', str(app)):
            profile += '(deny file-read* (subpath ' + json.dumps(denied) + '))'
        command = ['/usr/bin/sandbox-exec', '-p', profile, '/usr/bin/python3']
        subprocess.run(command + [str(source / 'test_managed_jam.py'), '--python', str(jam),
            '--binary', str(executable), '-v'] + tor_args, check=True)
        subprocess.run(command + [str(source / 'test_launcher_bridge.py'), '--helper', str(helper),
            '--jam-executable', str(jam), '--binary', str(executable), '-v'] + tor_runtime_args, check=True)
        if list(relocated.rglob('__pycache__')):
            raise RuntimeError('Application wrote bytecode inside its sealed bundle.')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(relocated)], check=True)
    print('Relocation, isolated helpers, crash/retry, clean close and post-run signature passed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    check(parser.parse_args().app.resolve(strict=True))
