"""Native Windows/Tk acceptance with an owned daemon and disposable empty storage."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import tkinter as tk
import unittest
from unittest.mock import Mock, patch
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


class NodeReviewDialog(unittest.TestCase):
    """Exercise real Windows modal buttons; intercept the subsequent setup RPC."""
    def test_cancel_preserves_edits_and_confirmation_submits_once_without_displaying_password(self):
        from tkinter import ttk
        root = tk.Tk()
        # This narrow dialog fixture owns no daemon, wallet, or saved connection.
        window = Window.__new__(Window)
        window.root = root
        window.replacing_node = True
        window.action = tk.Button(root)
        window.progress = ttk.Progressbar(root)
        window.status = tk.Label(root)
        window.session = Mock()
        window.setup_panel = None
        password = 'public-test-password-not-for-review'
        try:
            window.show_setup()
            window.setup_fields['endpoint'].insert(0, 'https://127.0.0.1:18443')
            window.setup_fields['username'].insert(0, 'fixture-user')
            window.setup_fields['password'].insert(0, password)
            window.setup_tor.set(True)
            root.update()
            self.assertTrue(window.setup_panel.winfo_viewable())
            self.assertTrue(window.setup_fields['password']['show'])
            for choice in (win32con.IDCANCEL, win32con.IDOK):
                observed = []
                errors = []
                def respond():
                    handle = None
                    try:
                        deadline = time.monotonic() + 10
                        while handle is None and time.monotonic() < deadline:
                            matches = []
                            def inspect(hwnd, _):
                                if (win32process.GetWindowThreadProcessId(hwnd)[1] == os.getpid()
                                        and win32gui.IsWindowVisible(hwnd)
                                        and win32gui.GetClassName(hwnd) == '#32770'
                                        and win32gui.GetWindowText(hwnd) == 'Review node change'):
                                    matches.append(hwnd)
                            win32gui.EnumWindows(inspect, None)
                            if matches: handle = matches[0]
                            else: time.sleep(.02)
                        if handle is None:
                            errors.append('Native node review dialog did not appear')
                            # Close only this disposable test window if modal
                            # discovery fails; never address another process.
                            win32gui.PostMessage(parent, win32con.WM_CLOSE, 0, 0)
                            return
                        labels = []
                        win32gui.EnumChildWindows(handle, lambda hwnd, _: labels.append(win32gui.GetWindowText(hwnd)), None)
                        observed.append(' '.join(labels))
                    except Exception:
                        errors.append('Could not inspect the native node review dialog')
                    finally:
                        if handle is not None:
                            try:
                                button = win32gui.GetDlgItem(handle, choice if not errors else win32con.IDCANCEL)
                                win32gui.PostMessage(button, win32con.BM_CLICK, 0, 0)
                            except Exception:
                                errors.append('Could not activate the native review button')
                                win32gui.PostMessage(handle, win32con.WM_CLOSE, 0, 0)
                parent = win32gui.GetAncestor(root.winfo_id(), win32con.GA_ROOT)
                responder = threading.Thread(target=respond, daemon=True)
                responder.start()
                window.setup_submit.invoke()
                responder.join(timeout=12)
                self.assertFalse(responder.is_alive(), 'Native dialog responder did not finish')
                self.assertFalse(errors, errors)
                self.assertEqual(len(observed), 1)
                self.assertIn('https://127.0.0.1:18443', observed[0])
                self.assertIn('fixture-user', observed[0])
                self.assertIn('Tor: On', observed[0])
                self.assertNotIn(password, observed[0])
                if choice == win32con.IDCANCEL:
                    window.session.setup.assert_not_called()
                    self.assertEqual(window.setup_fields['password'].get(), password)
                    self.assertEqual(str(window.setup_submit['state']), 'normal')
                else:
                    window.session.setup.assert_called_once()
                    request = window.session.setup.call_args.args[0]
                    self.assertEqual(request['action'], 'replace_jars')
                    self.assertIs(request['confirmed'], True)
                    self.assertTrue(request['settings']['password'] == password)
                    self.assertEqual(window.setup_fields['password'].get(), '')
                    self.assertEqual(str(window.setup_submit['state']), 'disabled')
                    window.setup_submit.invoke()
                    window.session.setup.assert_called_once()
        finally:
            try: root.destroy()
            except tk.TclError: pass


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
            setup_dismissed = False
            expect_setup = json.loads((EXECUTABLE.parent / 'runtime.json').read_text())['jars']
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
                    if setup and not setup_dismissed:
                        self.assertFalse((data / 'jars').exists())
                        self.assertFalse((data / 'wallet').exists())
                        win32gui.PostMessage(setup[0], win32con.WM_CLOSE, 0, 0)
                        setup_dismissed = True
                    if matches:
                        handle = matches[0]
                    time.sleep(.05)
                self.assertEqual(setup_dismissed, expect_setup)
                self.assertFalse((data / 'jars').exists())
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
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--executable', type=Path)
    parser.add_argument('--dialog-only', action='store_true', help='Test the native review dialog without a wallet daemon')
    args, remaining = parser.parse_known_args()
    if not args.dialog_only and args.binary is None:
        parser.error('--binary is required for daemon and packaged-window tests')
    BINARY = args.binary.resolve(strict=True) if args.binary else None
    EXECUTABLE = args.executable.resolve(strict=True) if args.executable else None
    unittest.main(argv=[sys.argv[0]] + remaining, defaultTest='NodeReviewDialog' if args.dialog_only else None)
