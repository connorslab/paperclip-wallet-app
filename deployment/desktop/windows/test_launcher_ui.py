"""Native Windows/Tk acceptance with an owned daemon and disposable empty storage."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import tkinter as tk
import unittest
from unittest.mock import patch
from urllib.request import Request, ProxyHandler, build_opener

import win32api
import win32con
import win32event
import win32gui
import win32process

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from windows.launcher import Window, valid_handoff
from windows.private_storage import SessionRecord, read_private_file
from windows.test_managed_daemon import DiagnosticDaemon
from managed_daemon import NoRedirects, local_endpoint

BINARY = None
EXECUTABLE = None


def private_bytes(path):
    with read_private_file(path) as file:
        return file.read()


@patch('linux.launcher.ManagedDaemon', DiagnosticDaemon)
class PreviewWindow(unittest.TestCase):
    def pump(self, predicate, timeout=35):
        deadline = time.monotonic() + timeout
        while not predicate():
            if not self.window.closed:
                self.root.update()
            self.assertLess(time.monotonic(), deadline, 'Preview did not reach the expected state')
            time.sleep(.02)

    def test_window_handoff_crash_retry_and_clean_close(self):
        with tempfile.TemporaryDirectory(prefix='paperclip-windows-window-qa-') as temporary:
            data = Path(temporary) / 'app'
            self.root = tk.Tk()
            opened = []
            self.window = Window(self.root, BINARY, data, opener=lambda url: opened.append(url) or True)
            try:
                self.pump(lambda: self.window.state in ('ready', 'failed'))
                self.assertEqual(self.window.state, 'ready', self.window.failure)
                self.assertFalse(self.window.recovery)
                self.window.action.invoke()
                self.pump(lambda: len(opened) == 1 and str(self.window.action['state']) == 'normal')
                self.assertTrue(valid_handoff(opened[0]))
                owner = private_bytes(data / 'wallet/auth_token')
                self.assertTrue(owner.strip().decode() not in opened[0])
                handle = win32api.OpenProcess(win32con.PROCESS_TERMINATE | win32con.SYNCHRONIZE,
                    False, int(private_bytes(data / 'wallet/barkd.lock')))
                try:
                    win32api.TerminateProcess(handle, 1)
                    self.assertEqual(win32event.WaitForSingleObject(handle, 5000), win32event.WAIT_OBJECT_0)
                finally:
                    handle.Close()
                self.pump(lambda: self.window.state == 'failed')
                self.assertEqual(str(self.window.action['text']), 'Try Again')
                self.window.action.invoke()
                self.pump(lambda: self.window.state in ('ready', 'failed'))
                self.assertEqual(self.window.state, 'ready', self.window.failure)
                self.assertTrue(self.window.recovery)
                self.assertEqual(str(self.window.action['text']), 'Review Wallet')
                self.assertEqual(len(opened), 1, 'Retry must not open or repeat a request')
                self.assertTrue(private_bytes(data / 'wallet/auth_token') == owner)
                self.root.geometry('420x420'); self.root.update()
                for widget in self.window.status.master.winfo_children():
                    if widget.winfo_ismapped():
                        self.assertGreaterEqual(widget.winfo_rooty(), self.root.winfo_rooty())
                        self.assertLessEqual(widget.winfo_rooty() + widget.winfo_height(),
                                             self.root.winfo_rooty() + self.root.winfo_height())
                self.window.close(); self.pump(lambda: self.window.closed)
                self.assertFalse(self.root.tk.call('after', 'info'), 'Closed window retained UI callbacks')
                self.assertEqual(private_bytes(data / 'session.state'), SessionRecord.CLOSED)
                self.assertFalse((data / 'wallet/mnemonic').exists())
            finally:
                if not self.window.closed:
                    self.window.close(); self.pump(lambda: self.window.closed)

    def test_missing_daemon_has_a_visible_retry_and_can_close(self):
        with tempfile.TemporaryDirectory(prefix='paperclip-windows-missing-qa-') as temporary:
            self.root = tk.Tk()
            self.window = Window(self.root, Path(temporary) / 'missing.exe', Path(temporary) / 'app')
            try:
                self.pump(lambda: self.window.state == 'failed')
                self.assertTrue(self.window.status['text'])
                self.assertEqual(str(self.window.action['text']), 'Try Again')
            finally:
                self.window.close(); self.pump(lambda: self.window.closed)
                self.assertFalse(self.root.tk.call('after', 'info'), 'Closed failure window retained UI callbacks')

    def test_damaged_packaged_runtime_shows_recovery_without_starting_wallet(self):
        if EXECUTABLE is None:
            self.skipTest('Pass --executable to test the frozen window entry point')
        # EXECUTABLE is a disposable QA package, never an installed/funded app.
        configuration = EXECUTABLE.parent / 'runtime.json'
        original = configuration.read_bytes()
        try:
            configuration.write_text('{"format":true,"jars":false}')
            with tempfile.TemporaryDirectory(prefix='paperclip-windows-damaged-qa-') as temporary:
                data = Path(temporary) / 'app'
                child = subprocess.Popen([str(EXECUTABLE), '--qa-root', str(data)],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                handle = None
                try:
                    deadline = time.monotonic() + 20
                    while handle is None:
                        self.assertIsNone(child.poll(), 'Damaged package exited without a visible explanation')
                        self.assertLess(time.monotonic(), deadline, 'Setup recovery dialog did not appear')
                        matches = []
                        def inspect(hwnd, _):
                            if (win32process.GetWindowThreadProcessId(hwnd)[1] == child.pid
                                    and win32gui.IsWindowVisible(hwnd)
                                    and win32gui.GetWindowText(hwnd) == 'Paperclip setup required'):
                                matches.append(hwnd)
                        win32gui.EnumWindows(inspect, None)
                        if matches:
                            handle = matches[0]
                        time.sleep(.05)
                    text = []
                    win32gui.EnumChildWindows(handle, lambda hwnd, _: text.append(win32gui.GetWindowText(hwnd)), None)
                    self.assertIn('Your saved wallets have not been changed.', ' '.join(text))
                    self.assertFalse(data.exists(), 'Invalid package must not initialize wallet storage')
                    win32gui.PostMessage(handle, win32con.WM_CLOSE, 0, 0)
                    self.assertEqual(child.wait(timeout=10), 1)
                finally:
                    if child.poll() is None:
                        child.kill(); child.wait(timeout=5)
        finally:
            configuration.write_bytes(original)

    def test_packaged_window_owns_daemon_and_closes_via_native_window_message(self):
        if EXECUTABLE is None:
            self.skipTest('Pass --executable to test the frozen window entry point')
        with tempfile.TemporaryDirectory(prefix='paperclip-windows-frozen-qa-') as temporary:
            data = Path(temporary) / 'app'
            child = subprocess.Popen([str(EXECUTABLE), '--qa-root', str(data)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            handle = None
            try:
                deadline = time.monotonic() + 35
                while handle is None or not (data / 'wallet/barkd.url').exists():
                    self.assertIsNone(child.poll(), 'Frozen window exited before readiness')
                    self.assertLess(time.monotonic(), deadline, 'Frozen window did not start')
                    matches = []; setup = []
                    def inspect(hwnd, _):
                        if (win32process.GetWindowThreadProcessId(hwnd)[1] == child.pid
                                and win32gui.IsWindowVisible(hwnd)
                                and win32gui.GetWindowText(hwnd) == 'Paperclip Preview'):
                            matches.append(hwnd)
                        if (win32process.GetWindowThreadProcessId(hwnd)[1] == child.pid
                                and win32gui.IsWindowVisible(hwnd)
                                and win32gui.GetWindowText(hwnd) == 'Set up Jars'):
                            setup.append(hwnd)
                    win32gui.EnumWindows(inspect, None)
                    if setup:
                        self.assertFalse((data / 'jars').exists())
                        self.assertFalse((data / 'wallet').exists())
                        win32gui.PostMessage(setup[0], win32con.WM_CLOSE, 0, 0)
                    if matches:
                        handle = matches[0]
                    time.sleep(.05)
                token = private_bytes(data / 'wallet/auth_token').decode().strip()
                endpoint = local_endpoint(private_bytes(data / 'wallet/barkd.url').decode())
                http = build_opener(ProxyHandler({}), NoRedirects())
                with http.open(Request(endpoint + '/api/v1/wallet',
                        headers={'Authorization':'Bearer ' + token}), timeout=5) as response:
                    self.assertIn('fingerprint', json.loads(response.read(4096)))
                win32gui.PostMessage(handle, win32con.WM_CLOSE, 0, 0)
                self.assertEqual(child.wait(timeout=35), 0)
                self.assertEqual(private_bytes(data / 'session.state'), SessionRecord.CLOSED)
                self.assertFalse((data / 'wallet/mnemonic').exists())
            finally:
                if child.poll() is None:
                    if handle is not None:
                        win32gui.PostMessage(handle, win32con.WM_CLOSE, 0, 0)
                    try:
                        child.wait(timeout=35)
                    except subprocess.TimeoutExpired:
                        child.kill(); child.wait(timeout=5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--executable', type=Path)
    args, remaining = parser.parse_known_args()
    BINARY = args.binary.resolve(strict=True)
    EXECUTABLE = args.executable.resolve(strict=True) if args.executable else None
    unittest.main(argv=[sys.argv[0]] + remaining)
