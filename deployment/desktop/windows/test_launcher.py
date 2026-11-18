"""Windows browser policy checks; these never launch a real browser or wallet."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from windows import launcher


class BrowserPolicy(unittest.TestCase):
    def test_path_cleanup_excludes_only_bundle_and_relative_searches(self):
        value = r'C:\Windows\System32;C:\preview\_internal;C:\preview\_internal\tk;C:\preview\_internal-other;D:\browser;;relative'
        self.assertEqual(launcher.browser_path(value, r'C:\preview\_internal'),
                         r'C:\Windows\System32;C:\preview\_internal-other;D:\browser')

    def test_browser_child_resets_loader_before_shell_open(self):
        good = 'http://127.0.0.1:1234/#desktop-handoff=' + 'a' * 44
        with patch.object(os, 'name', 'nt'), patch.object(sys, 'frozen', True, create=True), \
                patch.object(sys, '_MEIPASS', r'C:\preview\_internal', create=True), \
                patch.dict(os.environ, {'PATH':r'C:\preview\_internal;C:\Windows'}, clear=True), \
                patch.object(launcher.ctypes, 'WinDLL', create=True) as library, \
                patch.object(os, 'startfile', create=True) as start:
            reset = library.return_value.SetDllDirectoryW
            reset.return_value = 0
            self.assertFalse(launcher.open_browser_child(good))
            start.assert_not_called()
            reset.return_value = 1
            def opened(url):
                reset.assert_called_with(None)
                self.assertEqual(os.environ['PATH'], r'C:\Windows')
                self.assertEqual(url, good)
            start.side_effect = opened
            self.assertTrue(launcher.open_browser_child(good))
            start.assert_called_once()

    def test_untrusted_urls_never_spawn_a_helper(self):
        good = 'http://127.0.0.1:1234/#desktop-handoff=' + 'a' * 44
        with patch.object(os, 'name', 'nt'), patch.object(subprocess, 'run') as run:
            for url in ('https://untrusted.example', good + '\n', good.replace('1234', '0'),
                        good.replace('127.0.0.1', 'localhost'), good[:-1]):
                self.assertFalse(launcher.open_default_browser(url))
            run.assert_not_called()

    def test_frozen_browser_runs_in_a_separate_helper_without_changing_parent(self):
        good = 'http://127.0.0.1:1234/#desktop-handoff=' + 'a' * 44
        before = os.environ.copy()
        with patch.object(os, 'name', 'nt'), patch.object(sys, 'frozen', True, create=True), \
                patch.object(subprocess, 'CREATE_NO_WINDOW', 0x08000000, create=True), \
                patch.object(subprocess, 'run') as run:
            run.return_value.returncode = 0
            self.assertTrue(launcher.open_default_browser(good))
            self.assertEqual(run.call_args.args[0], [sys.executable, '--open-browser', good])
            self.assertEqual(run.call_args.kwargs['stdout'], subprocess.DEVNULL)
            self.assertEqual(run.call_args.kwargs['stderr'], subprocess.DEVNULL)
            self.assertEqual(os.environ, before)
            run.side_effect = subprocess.TimeoutExpired('browser helper', 10)
            self.assertFalse(launcher.open_default_browser(good))


class PackageRuntime(unittest.TestCase):
    def test_missing_damaged_and_incomplete_runtime_fail_before_startup(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / 'Paperclip.exe'
            configuration = executable.parent / 'runtime.json'
            with self.assertRaises(OSError):
                launcher.packaged_jars(executable)
            for value in (b'null', b'[]', b'{', b'"secret synthetic content"',
                          b'{"format":true,"jars":false}', b'{"format":1,"jars":0}',
                          b'{"format":1,"jars":false,"extra":true}', b' ' * 4097):
                configuration.write_bytes(value)
                with self.assertRaises(ValueError):
                    launcher.packaged_jars(executable)
            configuration.write_text(json.dumps({'format':1, 'jars':True}))
            with self.assertRaises(ValueError):
                launcher.packaged_jars(executable)
            configuration.write_text(json.dumps({'format':1, 'jars':False}))
            self.assertIsNone(launcher.packaged_jars(executable))
            jars = executable.parent / 'PaperclipJars/PaperclipJars.exe'
            jars.parent.mkdir(); jars.write_bytes(b'fixture only')
            configuration.write_text(json.dumps({'format':1, 'jars':True}))
            self.assertEqual(launcher.packaged_jars(executable), jars)

    def test_visible_setup_error_closes_its_window(self):
        from unittest.mock import Mock
        root = Mock()
        with patch('tkinter.Tk', return_value=root), patch('tkinter.messagebox.showerror') as show:
            self.assertEqual(launcher.setup_error('Reinstall this package.'), 1)
            root.withdraw.assert_called_once()
            show.assert_called_once_with('Paperclip setup required', 'Reinstall this package.', parent=root)
            root.destroy.assert_called_once()


if __name__ == '__main__':
    unittest.main()
