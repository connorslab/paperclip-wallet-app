import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('emulator_boot', Path(__file__).with_name('run-emulator.py'))
boot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boot)

HOME = 'mCurrentFocus=Window{abc u0 com.android.launcher3/.uioverrides.QuickstepLauncher}'


class EmulatorBootTests(unittest.TestCase):
    def test_focus_requires_a_home_window_not_an_error_dialog_or_null(self):
        self.assertTrue(boot.home_focused(HOME))
        self.assertTrue(boot.home_focused(HOME.replace('com.android.launcher3', 'com.google.android.apps.nexuslauncher')))
        for text in ('mCurrentFocus=null', 'mCurrentFocus=Window{abc u0 Application Error: com.android.launcher3}',
                     'mCurrentFocus=Window{abc u0 xyz.paperclip.wallet/.MainActivity}', 'mFocusedApp=' + HOME[14:]):
            self.assertFalse(boot.home_focused(text))

    def test_boot_flag_alone_never_authorizes_input_or_tests(self):
        process = Mock(); process.poll.return_value = None
        polls, commands = [], []
        def adb(serial, *arguments):
            commands.append(arguments)
            if arguments[-1] == 'sys.boot_completed':
                polls.append(1); value = '1'
            elif 'get-started-user-state' in arguments:
                value = 'RUNNING_LOCKED' if len(polls) == 1 else 'RUNNING_UNLOCKED'
            else:
                value = 'mCurrentFocus=null' if len(polls) == 2 else HOME
            return subprocess.CompletedProcess([], 0, value)
        with tempfile.TemporaryDirectory() as directory, patch.object(boot, 'adb', side_effect=adb), \
                patch.object(boot.instrumentation, 'healthy_emulator') as healthy, patch.object(boot.time, 'sleep'):
            boot.wait_ready(process, 'emulator-5554', Path(directory))
        self.assertEqual(len(polls), 5)
        self.assertEqual(healthy.call_count, 5)
        self.assertFalse(any('input' in command for command in commands))

    def test_startup_anr_fails_without_waiting_for_it_to_disappear(self):
        process = Mock(); process.poll.return_value = None
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(boot, 'adb', return_value=subprocess.CompletedProcess([], 0, '1')) as adb, \
                patch.object(boot.instrumentation, 'healthy_emulator', side_effect=ValueError('ANR')) as healthy, \
                patch.object(boot.time, 'sleep') as sleep:
            with self.assertRaises(ValueError): boot.wait_ready(process, 'emulator-5554', Path(directory))
        self.assertEqual(adb.call_count, 1); self.assertEqual(healthy.call_count, 1); sleep.assert_not_called()

    def test_dead_or_never_ready_boot_fails(self):
        process = Mock(); process.poll.return_value = 1
        with tempfile.TemporaryDirectory() as directory, patch.object(boot, 'adb') as adb:
            with self.assertRaises(ValueError): boot.wait_ready(process, 'emulator-5554', Path(directory))
            with self.assertRaises(ValueError): boot.wait_ready(process, 'emulator-5554', Path(directory), timeout=0)
        adb.assert_not_called()

    def test_unsupported_user_state_command_fails_instead_of_hanging(self):
        process = Mock(); process.poll.return_value = None
        for code in (0, 1):
            with tempfile.TemporaryDirectory() as directory, patch.object(boot, 'adb', side_effect=[
                    subprocess.CompletedProcess([], 0, '1'), subprocess.CompletedProcess([], code, 'Unknown command'),
                    subprocess.CompletedProcess([], 0, HOME)]), \
                    patch.object(boot.instrumentation, 'healthy_emulator'), patch.object(boot.time, 'sleep') as sleep:
                with self.assertRaises(ValueError): boot.wait_ready(process, 'emulator-5554', Path(directory))
                sleep.assert_not_called()

    def test_existing_serial_or_unapproved_avd_is_never_adopted(self):
        with patch.object(boot.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'emulator-5554\toffline\n')), \
                patch.object(boot.subprocess, 'Popen') as start:
            for avd in ('Paperclip_CI_35', 'personal-wallet'):
                with self.assertRaises(ValueError): boot.run(avd, Path('/sdk'), Path('/unused'))
        start.assert_not_called()

    def test_failed_boot_preserves_diagnostics_and_stops_only_its_process(self):
        process = Mock(); process.poll.return_value = None
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(boot.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'List of devices attached\n')) as run, \
                patch.object(boot.subprocess, 'Popen', return_value=process) as start, \
                patch.object(boot, 'wait_ready', side_effect=ValueError('unhealthy')) as ready, \
                patch.object(boot, 'diagnostics') as diagnostics, patch.object(boot, 'stop_owned') as stop:
            with self.assertRaises(ValueError): boot.run('Paperclip_CI_35', Path('/sdk'), Path(directory))
        self.assertEqual(run.call_count, 1)  # Device inventory only; no tests or mutation.
        self.assertEqual(ready.call_count, 1); self.assertEqual(diagnostics.call_count, 1)
        self.assertTrue(start.call_args.kwargs['start_new_session']); stop.assert_called_once_with(process)

    def test_cleanup_never_uses_adb_or_kills_an_exited_owner(self):
        process = Mock(); process.pid = 123; process.poll.return_value = 0
        with patch.object(boot.os, 'killpg') as kill, patch.object(boot, 'adb') as adb:
            boot.stop_owned(process); kill.assert_not_called()
            process.poll.return_value = None
            process.wait.side_effect = [subprocess.TimeoutExpired('emulator', 20), 0]
            boot.stop_owned(process)
        self.assertEqual([call.args[0] for call in kill.call_args_list], [123, 123]); adb.assert_not_called()
        process.wait.side_effect = None
        with patch.object(boot.os, 'killpg', side_effect=ProcessLookupError):
            boot.stop_owned(process)
        process.wait.assert_called_with(timeout=20)


if __name__ == '__main__':
    unittest.main()
