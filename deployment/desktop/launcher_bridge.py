"""Private stdio protocol between the desktop shell and its owned wallet daemon.

stdout is a private pipe, not a log: open events carry a single-use browser URL.
Only ready, open, error and stopped events are emitted; owner secrets stay here.
"""
import argparse
import json
import os
from pathlib import Path
import select
import sys

from managed_daemon import ManagedDaemon, StartupError


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
        if not select.select([sys.stdin.fileno()], [], [], 0.2)[0]:
            continue
        chunk = os.read(sys.stdin.fileno(), 257)
        if not chunk:
            if pending:
                raise StartupError('The desktop request was interrupted.')
            return
        pending += chunk


def serve(binary, root, jam_runtime=None):
    runner = ManagedDaemon(binary, root, jam_runtime=jam_runtime)
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
    args = parser.parse_args()
    if bool(args.jam_python) != bool(args.jam_entry):
        parser.error('Supply both packaged Jars runtime paths')
    try:
        serve(args.binary, args.root, (args.jam_python, args.jam_entry) if args.jam_python else None)
    except BrokenPipeError:
        # Shell death already closes the lifetime chain; never print a traceback.
        sys.exit(1)
    except Exception as error:
        try:
            emit('error', message=str(error) if isinstance(error, StartupError) else 'The local wallet could not start.')
        except BrokenPipeError:
            pass
        sys.exit(1)
