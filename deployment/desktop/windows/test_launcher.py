"""Windows browser policy checks; these never launch a real browser or wallet."""
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from windows import launcher


class BrowserPolicy(unittest.TestCase):
    def test_path_cleanup_excludes_only_bundle_and_relative_searches(self):
        value = r'C:\Windows\System32;C:\preview\_internal;C:\preview\_internal\tk;C:\preview\_internal-other;D:\browser;;relative'
        self.assertEqual(launcher.browser_path(value, r'C:\preview\_internal'),
                         r'C:\Windows\System32;C:\preview\_internal-other;D:\browser')

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


if __name__ == '__main__':
    unittest.main()
