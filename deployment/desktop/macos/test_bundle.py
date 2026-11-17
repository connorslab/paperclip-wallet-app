"""Check a relocated Mac package without access to build-host dependencies.

Uses only disposable unfunded directories. No GUI, wallet creation or payment.
The system Python drives tests; all application code runs in the bundled helpers.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def check(app):
    source = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix='paperclip-relocation-') as temporary:
        relocated = Path(temporary).resolve() / 'Path With Spaces' / app.name
        shutil.copytree(app, relocated, symlinks=True)
        contents = relocated / 'Contents'
        configuration = json.loads((contents / 'Resources/runtime.json').read_text())
        if configuration != {'bundledHelpers': True}:
            raise RuntimeError('This check requires bundled helpers without external interpreters.')
        executable = contents / 'MacOS/paperclip-walletd'
        helpers = contents / 'Helpers'
        jam = helpers / 'PaperclipJars.app/Contents/MacOS/PaperclipJars'
        helper = helpers / 'PaperclipHelper.app/Contents/MacOS/PaperclipHelper'
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(relocated)], check=True)
        profile = '(version 1)(allow default)'
        for denied in ('/opt/homebrew', '/usr/local', str(app)):
            profile += '(deny file-read* (subpath ' + json.dumps(denied) + '))'
        command = ['/usr/bin/sandbox-exec', '-p', profile, '/usr/bin/python3']
        subprocess.run(command + [str(source / 'test_managed_jam.py'), '--python', str(jam),
            '--binary', str(executable), '-v'], check=True)
        subprocess.run(command + [str(source / 'test_launcher_bridge.py'), '--helper', str(helper),
            '--jam-executable', str(jam), '--binary', str(executable), '-v'], check=True)
        if list(relocated.rglob('__pycache__')):
            raise RuntimeError('Application wrote bytecode inside its sealed bundle.')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(relocated)], check=True)
    print('Relocation, isolated helpers, crash/retry, clean close and post-run signature passed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    check(parser.parse_args().app.resolve(strict=True))
