import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('direct_instrumentation', Path(__file__).with_name('run-instrumentation.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def event(name='one', code=0, current=1, count=1, cls='Expected'):
    return (f'INSTRUMENTATION_STATUS: class={cls}\nINSTRUMENTATION_STATUS: test={name}\n'
            f'INSTRUMENTATION_STATUS: current={current}\nINSTRUMENTATION_STATUS: numtests={count}\n'
            f'INSTRUMENTATION_STATUS_CODE: {code}\n')


def case(name='one', current=1, count=1, code=0, cls='Expected'):
    return event(name, 1, current, count, cls) + event(name, code, current, count, cls)


FINAL = 'INSTRUMENTATION_CODE: -1\n'


class DirectInstrumentationTest(unittest.TestCase):
    def test_complete_named_cases_and_skips_are_counted(self):
        output = case(count=3) + case('two', 2, 3, -4) + event('three', -3, 3, 3) + FINAL
        result = runner.verify(output, 'Expected')
        self.assertEqual(result['passed'], 1)
        self.assertEqual(result['tests'], {'one': 'passed', 'two': 'skipped', 'three': 'skipped'})

    def test_missing_crashed_wrong_duplicate_and_partial_results_fail(self):
        for output in ['', FINAL, 'OK (1 test)\n' + FINAL, event() + FINAL,
                       event(code=1) + FINAL, case() , case() + 'INSTRUMENTATION_CODE: 0\n',
                       case(cls='Other') + FINAL, case() + case(current=2, count=2) + FINAL,
                       case(count=2) + FINAL, case() + FINAL + FINAL,
                       case() + FINAL + case('two', 2, 2), case(code=-2) + FINAL,
                       case(code=-1) + FINAL, case(code=-3) + FINAL, case(code=-4) + FINAL,
                       case() + 'INSTRUMENTATION_FAILED: fixture\n' + FINAL,
                       case() + 'INSTRUMENTATION_STATUS: class=Expected\n' + FINAL,
                       event(code=1) + event(name='different') + FINAL,
                       case().replace('numtests=1', 'numtests=0') + FINAL,
                       case().replace('current=1', 'current=0') + FINAL,
                       case().replace('test=one', 'test=') + FINAL,
                       case().replace('numtests=1', 'numtests=bad') + FINAL,
                       case().replace('INSTRUMENTATION_STATUS: numtests=1\n', '') + FINAL,
                       case() + 'INSTRUMENTATION_RESULT: shortMsg=Process crashed\n' + FINAL]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                runner.verify(output, 'Expected')

    def test_multiline_stream_and_stack_do_not_replace_metadata(self):
        output = case().replace('INSTRUMENTATION_STATUS_CODE: 0',
                                'INSTRUMENTATION_STATUS: stream=.\nfixture detail\nINSTRUMENTATION_STATUS_CODE: 0')
        self.assertEqual(runner.verify(output + FINAL, 'Expected')['passed'], 1)
        with self.assertRaises(ValueError):
            runner.verify(output.replace('stream=.', 'class=Other') + FINAL, 'Expected')

    def test_physical_device_or_unexpected_class_never_dispatches(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(runner.subprocess, 'run') as execute:
            for serial, cls in [('physical-id', 'xyz.paperclip.wallet.NativeBridgeTest'),
                                ('emulator-5554', 'Other'), ('emulator-5554;bad', 'xyz.paperclip.wallet.NativeBridgeTest')]:
                with self.assertRaises(ValueError):
                    runner.run(serial, cls, Path(directory))
            execute.assert_not_called()

    def test_failure_retains_log_removes_stale_pass_and_never_retries(self):
        calls = []
        def execute(command, **kwargs):
            calls.append(command)
            if 'instrument' in command:
                kwargs['stdout'].write(case(code=-2, cls='xyz.paperclip.wallet.NativeBridgeTest') + FINAL)
            return runner.subprocess.CompletedProcess(command, 0)
        with tempfile.TemporaryDirectory() as directory, patch.object(runner.subprocess, 'run', side_effect=execute):
            path = Path(directory)
            (path / 'result.json').write_text('{"passed":99}')
            with self.assertRaisesRegex(ValueError, 'retained report'):
                runner.run('emulator-5554', 'xyz.paperclip.wallet.NativeBridgeTest', path)
            self.assertFalse((path / 'result.json').exists())
            self.assertIn('INSTRUMENTATION_STATUS_CODE: -2', (path / 'instrumentation.log').read_text())
            self.assertEqual(sum('instrument' in command for command in calls), 1)
            self.assertTrue(all(command[:3] == ['adb', '-s', 'emulator-5554'] for command in calls))
            self.assertTrue((path / 'last-anr.log').exists())

    def test_existing_anr_prevents_dispatch_without_clearing_or_retrying(self):
        calls = []
        def execute(command, **kwargs):
            calls.append(command)
            if 'logcat' in command:
                kwargs['stdout'].write("I/am_anr  ( 564): [0,832,com.android.systemui,123,startup failed]\n")
            return runner.subprocess.CompletedProcess(command, 0)
        with tempfile.TemporaryDirectory() as directory, patch.object(runner.subprocess, 'run', side_effect=execute):
            path = Path(directory)
            with self.assertRaises(ValueError):
                runner.run('emulator-5554', 'xyz.paperclip.wallet.NativeBridgeTest', path)
            self.assertFalse(any('instrument' in command for command in calls))
            self.assertFalse(any('-c' in command for command in calls))
            self.assertFalse((path / 'result.json').exists())
            self.assertIn('am_anr', (path / 'before-anr-events.log').read_text())

    def test_anr_after_passing_tests_still_fails_acceptance(self):
        calls, event_reads = [], []
        def execute(command, **kwargs):
            calls.append(command)
            if 'instrument' in command:
                kwargs['stdout'].write(case(cls='xyz.paperclip.wallet.NativeBridgeTest') + FINAL)
            elif 'logcat' in command:
                event_reads.append(True)
                if len(event_reads) > 1:
                    kwargs['stdout'].write('I/am_anr  ( 564): [0,123,com.android.launcher3,123,fixture]\n')
            return runner.subprocess.CompletedProcess(command, 0)
        with tempfile.TemporaryDirectory() as directory, patch.object(runner.subprocess, 'run', side_effect=execute):
            path = Path(directory)
            with self.assertRaises(ValueError):
                runner.run('emulator-5554', 'xyz.paperclip.wallet.NativeBridgeTest', path)
            self.assertFalse((path / 'result.json').exists())
            self.assertEqual(sum('instrument' in command for command in calls), 1)
            self.assertIn('am_anr', (path / 'after-anr-events.log').read_text())
