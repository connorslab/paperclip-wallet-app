"""Native Windows development window; starting it never creates a funded wallet."""
import argparse
import ctypes
import json
import ntpath
import os
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from linux.launcher import Window, valid_handoff
from managed_daemon import default_data_root


def browser_path(value, runtime):
    """Remove bundled DLL directories and implicit working-directory lookups."""
    runtime = ntpath.normcase(ntpath.abspath(runtime))
    kept = []
    for part in value.split(';'):
        part = part.strip().strip('"')
        if not ntpath.isabs(part):
            continue
        path = ntpath.normcase(ntpath.abspath(part))
        try:
            bundled = ntpath.commonpath([path, runtime]) == runtime
        except ValueError:
            bundled = False
        if not bundled:
            kept.append(part)
    return ';'.join(kept)


def open_browser_child(url):
    if os.name != 'nt' or not valid_handoff(url):
        return False
    # Only this short-lived helper resets loader state. The UI's worker and Tk
    # can continue loading their bundled DLLs without a process-global race.
    if getattr(sys, 'frozen', False):
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        reset = kernel.SetDllDirectoryW
        reset.argtypes, reset.restype = [ctypes.c_wchar_p], ctypes.c_int
        if not reset(None):
            return False
        os.environ['PATH'] = browser_path(os.environ.get('PATH', ''), sys._MEIPASS)
    try:
        os.startfile(url)
        return True
    except OSError:
        return False


def open_default_browser(url):
    if os.name != 'nt' or not valid_handoff(url):
        return False
    command = [sys.executable]
    if not getattr(sys, 'frozen', False):
        command += ['-I', '-B', str(Path(__file__).resolve())]
    command += ['--open-browser', url]
    try:
        return subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW,
            timeout=10, check=False).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def main():
    if os.name != 'nt':
        raise SystemExit('Use the launcher for your operating system.')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--qa-root', type=Path)
    parser.add_argument('--jam-executable', type=Path)
    parser.add_argument('--open-browser', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.open_browser is not None:
        raise SystemExit(0 if open_browser_child(args.open_browser) else 1)
    binary = args.binary
    jars = args.jam_executable
    if getattr(sys, 'frozen', False):
        if jars is not None:
            parser.error('The packaged app uses only its bundled Jars runtime.')
        try:
            configuration = json.loads((Path(sys.executable).parent / 'runtime.json').read_text())
            if (set(configuration) != {'format','jars'} or configuration['format'] != 1
                    or not isinstance(configuration['jars'],bool)):
                raise ValueError('Invalid runtime configuration')
            if configuration['jars']:
                jars = Path(sys.executable).parent / 'PaperclipJars/PaperclipJars.exe'
                if not jars.is_file():raise ValueError('Missing Jars runtime')
        except (OSError, ValueError):
            parser.error('The packaged runtime is incomplete. Reinstall this Paperclip package.')
    if binary is None:
        if not getattr(sys, 'frozen', False):
            parser.error('Supply the development daemon with --binary')
        binary = Path(sys.executable).parent / 'paperclip-walletd.exe'
    if args.qa_root is not None and not args.qa_root.is_absolute():
        parser.error('QA storage must be an absolute, isolated path.')
    import tkinter as tk
    from tkinter import messagebox
    root = tk.Tk()
    try:
        data = args.qa_root if args.qa_root is not None else default_data_root()
    except Exception:
        root.withdraw()
        messagebox.showerror('Paperclip', 'Your private wallet folder is unavailable. Try opening Paperclip again.', parent=root)
        root.destroy()
        return
    Window(root, binary, data, opener=open_default_browser,
           jam_runtime=(jars, None) if jars is not None else None)
    root.mainloop()


if __name__ == '__main__':
    main()
