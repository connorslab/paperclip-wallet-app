"""Private stdio protocol between the desktop shell and its owned wallet daemon.

stdout is a private pipe, not a log: open events carry a single-use browser URL.
Setup events contain fixed progress and errors only; owner secrets stay here.
"""
import argparse
import json
import queue
from pathlib import Path
import sys
import threading

from managed_daemon import ManagedDaemon, StartupError
from pipe_io import read_available
from managed_tor import packaged_binary as packaged_tor_binary
from node_setup_client import choose_runtime, MAX_INPUT


def emit(event, **values):
    print(json.dumps({'event':event, **values}, separators=(',', ':')), flush=True)


class SetupInbox:
    def __init__(self):
        self.values=queue.Queue(maxsize=8)
        self.stopping=threading.Event()
        self.error=None
        threading.Thread(target=self.read,daemon=True).start()

    def read(self):
        pending=b''
        try:
            while not self.stopping.is_set():
                chunk=read_available(sys.stdin.fileno(),4096,0.2)
                if chunk is None:continue
                if not chunk:
                    if pending:raise ValueError()
                    break
                pending+=chunk
                while b'\n' in pending:
                    line,pending=pending.split(b'\n',1)
                    if len(line)>MAX_INPUT:raise ValueError()
                    self.values.put_nowait(json.loads(line))
                if len(pending)>MAX_INPUT:raise ValueError()
        except Exception:
            self.error=StartupError('The private setup request was interrupted or invalid.')
        finally:self.stopping.set()

    def receive(self):
        if self.error is not None:raise self.error
        try:return self.values.get(timeout=0.1)
        except queue.Empty:return None


def commands(runner, inbox=None):
    if inbox is not None:
        while True:
            runner.ensure_running()
            request=inbox.receive()
            if request is not None:yield request
            elif inbox.stopping.is_set():return
        return
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


def serve(binary, root, jam_runtime=None, tor_binary=None, guided_setup=False):
    inbox=None
    if guided_setup and jam_runtime is not None:
        inbox=SetupInbox()
        jam_runtime=choose_runtime(jam_runtime,root,tor_binary,inbox.stopping,inbox.receive,
            lambda event,value:emit(event,**({'message':value} if value else {})))
        if inbox.stopping.is_set():return
    runner = ManagedDaemon(binary, root, jam_runtime=jam_runtime, tor_binary=tor_binary)
    try:
        runner.start()
        emit('ready', recovery_required=runner.recovery_required)
        for request in commands(runner,inbox):
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
    parser.add_argument('--guided-setup', action='store_true')
    args = parser.parse_args()
    if args.jam_executable and (args.jam_python or args.jam_entry):
        parser.error('Choose the bundled Jars executable or development Python paths')
    if bool(args.jam_python) != bool(args.jam_entry):
        parser.error('Supply both packaged Jars runtime paths')
    try:
        tor = packaged_tor_binary(args.tor_runtime) if args.tor_runtime else None
        serve(args.binary, args.root, (args.jam_executable, None) if args.jam_executable else ((args.jam_python, args.jam_entry) if args.jam_python else None), tor_binary=tor, guided_setup=args.guided_setup)
    except BrokenPipeError:
        # Shell death already closes the lifetime chain; never print a traceback.
        sys.exit(1)
    except Exception as error:
        try:
            emit('error', message=str(error) if isinstance(error, StartupError) else 'The local wallet could not start.')
        except BrokenPipeError:
            pass
        sys.exit(1)
