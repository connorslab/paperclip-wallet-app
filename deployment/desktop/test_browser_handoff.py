"""Real Chromium and owned daemon acceptance with isolated, unfunded storage."""
import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile

from managed_daemon import ManagedDaemon


def check(binary, node):
    script = Path(__file__).resolve().parents[2] / 'scripts' / 'test-desktop-handoff-browser.cjs'
    with tempfile.TemporaryDirectory(prefix='paperclip-browser-handoff-qa-') as temporary:
        root = Path(temporary) / 'app'
        with ManagedDaemon(binary, root) as runner:
            owner = (root / 'wallet' / 'auth_token').read_bytes()
            for width in (390, 1280):
                # Handoff codes are private pipe input, never process arguments,
                # artifacts, environment variables or diagnostic output.
                print('Check native browser handoff at width ' + str(width), flush=True)
                env = dict(os.environ, NATIVE_VIEWPORT=str(width))
                process = subprocess.Popen([str(node), str(script), '--native'],
                    stdin=subprocess.PIPE, text=True, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, start_new_session=True, env=env)
                try:
                    output, errors = process.communicate(runner.browser_url(), timeout=45)
                except subprocess.TimeoutExpired:
                    # Stop only this test's process group, including Chromium.
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()
                    raise RuntimeError('Native browser check timed out.') from None
                if process.returncode != 0 or not output.startswith('PASS native browser handoff:'):
                    for stage in ('launch', 'sign-in', 'refresh', 'replay'):
                        if 'Native desktop browser handoff failed at ' + stage + '; credentials omitted.' in errors:
                            print('Native browser failure stage: ' + stage, flush=True)
                    raise RuntimeError('Native browser check failed; private diagnostics omitted.')
                assert (root / 'wallet' / 'auth_token').read_bytes() == owner
                assert not (root / 'wallet' / 'mnemonic').exists()
            # A fresh handoff succeeds on the second browser after the first
            # browser rejected a consumed grant. No automatic request repeats.
        assert runner.process.returncode == 0
        assert not (root / 'session.active').exists()
        assert (root / 'wallet' / 'auth_token').read_bytes() == owner
        assert not (root / 'wallet' / 'mnemonic').exists()
    print('PASS native browser lifecycle: both viewports, fresh grant after replay rejection, clean shutdown, no wallet created')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--node', type=Path, default=shutil.which('node'))
    args = parser.parse_args()
    if args.node is None:
        parser.error('A Node executable is required.')
    try:
        check(args.binary.resolve(strict=True), Path(args.node).resolve(strict=True))
    except Exception:
        raise SystemExit('Native desktop browser acceptance failed; private diagnostics omitted.')
