"""Private stdio protocol between the desktop shell and its owned wallet daemon.

stdout is a private pipe, not a log: open events carry a single-use browser URL.
Only ready, open, error and stopped events are emitted; owner secrets stay here.
"""
import argparse
import json
from pathlib import Path
import sys

from managed_daemon import ManagedDaemon, StartupError
from pipe_io import read_available
from managed_tor import packaged_binary as packaged_tor_binary


def emit(event, **values):
    print(json.dumps({'event':event, **values}, separators=(',', ':')), flush=True)


def commands(runner):
    pending = b''
    while True:
        runner.ensure_running()
        if b'\n' in pending:
            line, pending = pending.split(b'\n', 1)
            if len(line) > 256:
                raise StartupError('The desktop request was too large.')
            try:
                yield json.loads(line)
            except (ValueError, UnicodeError):
                raise StartupError('The desktop request was not recognized.') from None
            continue
        if len(pending) > 256:
            raise StartupError('The desktop request was too large.')
        chunk = read_available(sys.stdin.fileno(), 257, 0.2)
        if chunk is None:
            continue
        if not chunk:
            if pending:
                raise StartupError('The desktop request was interrupted.')
            return
        pending += chunk


def serve(binary, root, jam_runtime=None, tor_binary=None):
    runner = ManagedDaemon(binary, root, jam_runtime=jam_runtime, tor_binary=tor_binary)
    try:
        runner.start()
        emit('ready', recovery_required=runner.recovery_required)
        for request in commands(runner):
            if request == {'action':'quit'}:
                break
            if request != {'action':'open'}:
                raise StartupError('The desktop request was not recognized.')
            try:
                emit('open', url=runner.browser_url())
            except StartupError as error:
                emit('error', message=str(error))
    finally:
        runner.close()
    emit('stopped')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--jam-python', type=Path)
    parser.add_argument('--jam-entry', type=Path)
    parser.add_argument('--jam-executable', type=Path)
    parser.add_argument('--tor-runtime', type=Path)
    args = parser.parse_args()
    if args.jam_executable and (args.jam_python or args.jam_entry):
        parser.error('Choose the bundled Jars executable or development Python paths')
    if bool(args.jam_python) != bool(args.jam_entry):
        parser.error('Supply both packaged Jars runtime paths')
    try:
        tor = packaged_tor_binary(args.tor_runtime) if args.tor_runtime else None
        serve(args.binary, args.root, (args.jam_executable, None) if args.jam_executable else ((args.jam_python, args.jam_entry) if args.jam_python else None), tor_binary=tor)
    except BrokenPipeError:
        # Shell death already closes the lifetime chain; never print a traceback.
        sys.exit(1)
    except Exception as error:
        try:
            emit('error', message=str(error) if isinstance(error, StartupError) else 'The local wallet could not start.')
        except BrokenPipeError:
            pass
        sys.exit(1)
