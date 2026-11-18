"""Linux/Xvfb acceptance for a packaged preview, using an empty owned wallet."""
import argparse
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import tkinter as tk
import unittest

BINARY = None
LAUNCHER = None
SCREENSHOTS = None
JARS = None
TOR = None


class PreviewWindow(unittest.TestCase):
    def pump(self, predicate, timeout=12):
        deadline = time.monotonic() + timeout
        while not predicate():
            if not self.window.closed:
                self.root.update()
            self.assertLess(time.monotonic(), deadline, 'Preview did not reach the expected state')
            time.sleep(.02)

    def capture(self, name):
        self.root.update_idletasks()
        if SCREENSHOTS:
            SCREENSHOTS.mkdir(parents=True, exist_ok=True)
            subprocess.run(['import', '-window', str(self.root.winfo_id()), str(SCREENSHOTS / name)], check=True)

    def test_packaged_preview_opens_once_recovers_and_closes_cleanly(self):
        if LAUNCHER is None:
            import launcher as module
        else:
            spec = importlib.util.spec_from_file_location('packaged_linux_launcher', LAUNCHER)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='paperclip-linux-window-qa-') as temporary:
            data = Path(temporary) / 'app'
            self.root = tk.Tk()
            opened = []
            self.window = module.Window(self.root, BINARY, data, opener=lambda url: opened.append(url) or True,
                                        jam_runtime=(JARS, None) if JARS else None, tor_runtime=TOR)
            try:
                if JARS:
                    self.pump(lambda: self.window.setup_panel is not None)
                    self.assertFalse((data / 'jars').exists())
                    self.window.defer_setup()
                self.pump(lambda: self.window.state == 'ready')
                self.assertFalse(self.window.recovery)
                self.assertEqual(str(self.window.action['text']), 'Open Wallet')
                self.capture('linux-ready.png')
                self.window.action.invoke()
                self.pump(lambda: len(opened) == 1 and str(self.window.action['state']) == 'normal')
                self.assertTrue(module.valid_handoff(opened[0]))
                owner = (data / 'wallet' / 'auth_token').read_bytes()
                self.assertTrue(owner.strip().decode() not in opened[0])
                os.kill(int((data / 'wallet' / 'barkd.lock').read_text()), signal.SIGKILL)
                self.pump(lambda: self.window.state == 'failed')
                self.assertEqual(str(self.window.action['text']), 'Try Again')
                self.window.action.invoke()
                if JARS:
                    self.pump(lambda: self.window.setup_panel is not None)
                    self.assertFalse((data / 'jars').exists())
                    self.window.defer_setup()
                self.pump(lambda: self.window.state == 'ready')
                self.assertTrue(self.window.recovery)
                self.assertEqual(str(self.window.action['text']), 'Review Wallet')
                self.assertEqual(len(opened), 1, 'Retry must not automatically open or repeat a request')
                self.assertTrue((data / 'wallet' / 'auth_token').read_bytes() == owner)
                self.root.geometry('420x420')
                self.root.update()
                for widget in self.window.status.master.winfo_children():
                    if not widget.winfo_ismapped():
                        continue
                    self.assertGreaterEqual(widget.winfo_rooty(), self.root.winfo_rooty())
                    self.assertLessEqual(widget.winfo_rooty() + widget.winfo_height(), self.root.winfo_rooty() + self.root.winfo_height())
                self.capture('linux-recovery-compact.png')
                self.window.close()
                self.pump(lambda: self.window.closed)
                self.assertFalse(self.root.tk.call('after', 'info'), 'Closed window retained UI callbacks')
                self.assertFalse((data / 'session.active').exists())
                self.assertFalse((data / 'wallet' / 'mnemonic').exists())
                self.assertFalse(list(data.rglob('*.jmdat')))
            finally:
                if not self.window.closed:
                    self.window.close()
                    self.pump(lambda: self.window.closed, timeout=35)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--launcher', type=Path)
    parser.add_argument('--screenshots', type=Path)
    parser.add_argument('--jam-executable', type=Path)
    parser.add_argument('--tor-runtime', type=Path)
    args, remaining = parser.parse_known_args()
    BINARY, LAUNCHER = args.binary.resolve(strict=True), args.launcher.resolve(strict=True) if args.launcher else None
    TOR = args.tor_runtime.resolve(strict=True) if args.tor_runtime else None
    SCREENSHOTS = args.screenshots
    JARS = args.jam_executable.resolve(strict=True) if args.jam_executable else None
    unittest.main(argv=[sys.argv[0]] + remaining)
