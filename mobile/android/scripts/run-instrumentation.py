"""Run one synthetic emulator test class, retaining evidence and rejecting partial runs.

Status codes follow AndroidJUnitRunner's InstrumentationResultPrinter:
https://github.com/android/android-test/blob/main/runner/android_junit_runner/java/androidx/test/internal/runner/listener/InstrumentationResultPrinter.java
"""
import argparse
import json
from pathlib import Path
import re
import subprocess


def verify(output, expected_class):
    packet, active, completed = {}, None, {}
    total, final = None, None
    for line in output.splitlines():
        if line.startswith('INSTRUMENTATION_STATUS: '):
            key, separator, value = line[24:].partition('=')
            if separator and key in ('class', 'test', 'current', 'numtests'):
                if key in packet:
                    raise ValueError('Duplicate instrumentation field')
                packet[key] = value
        elif line.startswith('INSTRUMENTATION_STATUS_CODE: '):
            if final is not None:
                raise ValueError('Test event after final result')
            code = int(line.split(': ', 1)[1])
            if packet.get('class') != expected_class or not packet.get('test'):
                raise ValueError('Missing or unexpected instrumentation class/name')
            count, current = int(packet.get('numtests', '')), int(packet.get('current', ''))
            if count <= 0 or (total is not None and total != count) or current != len(completed) + 1:
                raise ValueError('Instrumentation count or order changed')
            total = count
            name = packet['test']
            if name in completed:
                raise ValueError('Duplicate instrumentation test')
            if code == 1:
                if active is not None:
                    raise ValueError('Previous test did not finish')
                active = name
            elif code in (0, -3, -4):
                if active != name and not (code == -3 and active is None):
                    raise ValueError('Test completion has no matching start')
                completed[name] = 'passed' if code == 0 else 'skipped'
                active = None
            else:
                raise ValueError('Instrumentation test failed or returned an unknown status')
            packet = {}
        elif line.startswith('INSTRUMENTATION_CODE: '):
            if final is not None:
                raise ValueError('Multiple final instrumentation results')
            final = int(line.split(': ', 1)[1])
        elif line.startswith(('INSTRUMENTATION_FAILED:', 'INSTRUMENTATION_ABORTED:',
                              'INSTRUMENTATION_RESULT: shortMsg=', 'INSTRUMENTATION_RESULT: longMsg=')):
            raise ValueError('Instrumentation runner failed')
    if final != -1 or active is not None or packet or total != len(completed):
        raise ValueError('Instrumentation run is missing its complete result')
    if not completed or 'passed' not in completed.values():
        raise ValueError('Requested class had no passing non-skipped tests')
    return {'class': expected_class, 'tests': completed, 'passed': list(completed.values()).count('passed')}



def healthy_emulator(serial, directory, phase):
    # Never clear the event buffer: startup ANRs also invalidate UI acceptance.
    path = directory / (phase + '-anr-events.log')
    with path.open('w') as output:
        result = subprocess.run(['adb', '-s', serial, 'logcat', '-b', 'events', '-d',
                                 '-v', 'brief', '-s', 'am_anr'], stdout=output,
                                stderr=subprocess.STDOUT, timeout=10)
    if result.returncode or re.search(r'^\s*[VDIWEF]/am_anr\s*\(', path.read_text(), re.MULTILINE):
        raise ValueError('Emulator ANR history is unhealthy or unavailable')


def run(serial, expected_class, directory):
    if not re.fullmatch(r'emulator-[0-9]+', serial) or not re.fullmatch(r'xyz\.paperclip\.wallet\.[A-Za-z0-9]+Test', expected_class):
        raise ValueError('Use an explicitly selected emulator and a Paperclip test class')
    directory.mkdir(parents=True, exist_ok=True)
    log = directory / 'instrumentation.log'
    result_file = directory / 'result.json'
    result_file.unlink(missing_ok=True)
    try:
        healthy_emulator(serial, directory, 'before')
        with log.open('w') as output:
            result = subprocess.run(['adb', '-s', serial, 'shell', 'am', 'instrument', '-w', '-r',
                '-e', 'class', expected_class,
                'xyz.paperclip.wallet.android.preview.test/androidx.test.runner.AndroidJUnitRunner'],
                stdout=output, stderr=subprocess.STDOUT, timeout=300)
        if result.returncode:
            raise ValueError('ADB instrumentation command failed')
        verified = verify(log.read_text(), expected_class)
        healthy_emulator(serial, directory, 'after')
        result_file.write_text(json.dumps(verified, indent=2) + '\n')
        print(f'{expected_class}: {verified["passed"]} tests passed')
    except (ValueError, KeyError, subprocess.TimeoutExpired):
        # This runner is only used with disposable synthetic emulator fixtures.
        # Keep ANR evidence; never dismiss dialogs or retry the failed class.
        for name, arguments in [('anr-events', ['logcat', '-b', 'events', '-d', '-v', 'brief', '-s', 'am_anr', 'am_crash']),
                                ('last-anr', ['shell', 'dumpsys', 'activity', 'lastanr']),
                                ('memory', ['shell', 'cat', '/proc/meminfo'])]:
            with (directory / (name + '.log')).open('w') as output:
                try:
                    subprocess.run(['adb', '-s', serial] + arguments, stdout=output,
                                   stderr=subprocess.STDOUT, timeout=10)
                except subprocess.TimeoutExpired:
                    pass
        with (directory / 'blocked-screen.png').open('wb') as output:
            try:
                subprocess.run(['adb', '-s', serial, 'exec-out', 'screencap', '-p'],
                               stdout=output, stderr=subprocess.DEVNULL, timeout=10)
            except subprocess.TimeoutExpired:
                pass
        raise ValueError('Instrumentation did not pass; inspect the retained report') from None


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('serial')
    parser.add_argument('expected_class')
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    run(args.serial, args.expected_class, args.directory)
