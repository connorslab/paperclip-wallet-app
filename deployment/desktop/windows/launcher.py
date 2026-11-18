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



def packaged_jars(executable):
    """Reject an incomplete package before creating storage or starting children."""
    package = executable.parent
    with (package / 'runtime.json').open('rb') as file:
        encoded = file.read(4097)
    if len(encoded) > 4096:
        raise ValueError('Invalid runtime configuration')
    configuration = json.loads(encoded)
    if (not isinstance(configuration, dict) or set(configuration) != {'format', 'jars'}
            or type(configuration['format']) is not int or configuration['format'] != 1
            or type(configuration['jars']) is not bool):
        raise ValueError('Invalid runtime configuration')
    if not configuration['jars']:
        return None
    jars = package / 'PaperclipJars/PaperclipJars.exe'
    if not jars.is_file():
        raise ValueError('Missing Jars runtime')
    return jars


def setup_error(message):
    # Frozen Windows builds have no console: argparse.error would disappear
    # without telling the user why no wallet window opened.
    import tkinter as tk
    from tkinter import messagebox
    root = tk.Tk()
    root.withdraw()
    try:
        messagebox.showerror('Paperclip setup required', message, parent=root)
    finally:
        root.destroy()
    return 1


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
            return setup_error('This Paperclip package uses its bundled Jars service. Open it without an external Jars override.')
        try:
            jars = packaged_jars(Path(sys.executable))
        except (OSError, ValueError):
            return setup_error('Paperclip is missing required app files or its package is damaged. Reinstall Paperclip, then try again. Your saved wallets have not been changed.')
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
    raise SystemExit(main())
