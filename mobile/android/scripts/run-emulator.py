"""Own one disposable AVD and wait for a healthy, focused home before UI tests.

Never inject boot-time input, dismiss an ANR, clear logs or retry a failed boot.
The caller prepares the AVD and APKs first. Only this process's emulator is stopped.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time

SCRIPTS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('instrumentation', SCRIPTS / 'run-instrumentation.py')
instrumentation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(instrumentation)


def adb(serial, *arguments):
    return subprocess.run(['adb', '-s', serial, *arguments], text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)


def home_focused(windows):
    return bool(re.search(r'mCurrentFocus=Window\{[^}\n]*\bu0 '
                          r'(?:com\.android\.launcher3|com\.google\.android\.apps\.nexuslauncher)/[^}\n]+\}', windows))


def wait_ready(process, serial, report, timeout=600):
    deadline = time.monotonic() + timeout
    focused = 0
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise ValueError('Owned emulator exited before readiness')
        boot = adb(serial, 'shell', 'getprop', 'sys.boot_completed')
        if boot.returncode == 0 and boot.stdout.strip() == '1':
            # A previous ANR invalidates this boot even if its dialog disappears.
            instrumentation.healthy_emulator(serial, report, 'boot')
            unlocked = adb(serial, 'shell', 'am', 'get-started-user-state', '0')
            windows = adb(serial, 'shell', 'dumpsys', 'window')
            (report / 'boot-window.log').write_text(windows.stdout)
            if unlocked.returncode or windows.returncode:
                raise ValueError('Could not inspect the booted emulator user or windows')
            if unlocked.stdout.strip() not in ('BOOTING', 'RUNNING_LOCKED', 'RUNNING_UNLOCKING', 'RUNNING_UNLOCKED', 'STOPPING', 'SHUTDOWN'):
                raise ValueError('Emulator returned an unrecognized user state')
            ready = (unlocked.returncode == 0 and unlocked.stdout.strip() == 'RUNNING_UNLOCKED'
                     and windows.returncode == 0 and home_focused(windows.stdout))
            focused = focused + 1 if ready else 0
            if focused == 3:
                return
        else:
            focused = 0
        time.sleep(1)
    raise ValueError('Emulator did not reach an unlocked, focused home before the deadline')


def diagnostics(serial, report):
    for name, arguments in [('anr-events', ['logcat', '-b', 'events', '-d', '-v', 'brief', '-s', 'am_anr', 'am_crash']),
                            ('last-anr', ['shell', 'dumpsys', 'activity', 'lastanr']),
                            ('window', ['shell', 'dumpsys', 'window']),
                            ('memory', ['shell', 'cat', '/proc/meminfo'])]:
        try:
            (report / (name + '.log')).write_text(adb(serial, *arguments).stdout)
        except subprocess.TimeoutExpired:
            (report / (name + '.log')).write_text('Diagnostic command timed out\n')
    with (report / 'screen.png').open('wb') as output:
        try:
            subprocess.run(['adb', '-s', serial, 'exec-out', 'screencap', '-p'],
                           stdout=output, stderr=subprocess.DEVNULL, timeout=10)
        except subprocess.TimeoutExpired:
            pass


def stop_owned(process):
    if process.poll() is None:
        # start_new_session makes this group exclusive to our owned emulator.
        # Do not use adb emu kill: a different emulator could take its port later.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass  # It exited between poll and signal; still reap our child.
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=10)


def run(avd, sdk, reports, port=5554):
    if not re.fullmatch(r'Paperclip_(?:CI_[0-9]+|Recovery_20261117)', avd):
        raise ValueError('Select an explicitly named disposable Paperclip test AVD')
    if not 5554 <= port <= 5682 or port % 2:
        raise ValueError('Select an even emulator console port')
    serial = f'emulator-{port}'
    devices = subprocess.run(['adb', 'devices'], text=True, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, timeout=10, check=True).stdout
    if any(line.split()[0] == serial for line in devices.splitlines() if line.strip()):
        raise ValueError('Selected emulator serial is already in use; it will not be adopted')
    reports.mkdir(parents=True, exist_ok=True)
    report = Path(tempfile.mkdtemp(prefix='boot-', dir=reports))
    with (report / 'emulator.log').open('w') as output:
        process = subprocess.Popen([str(sdk / 'emulator' / 'emulator'), '-avd', avd, '-port', str(port),
            '-no-window', '-gpu', 'swiftshader', '-no-snapshot', '-noaudio', '-no-boot-anim'],
            stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            wait_ready(process, serial, report)
            for setting in ('window_animation_scale', 'transition_animation_scale', 'animator_duration_scale'):
                if adb(serial, 'shell', 'settings', 'put', 'global', setting, '0.0').returncode:
                    raise ValueError('Could not configure test animations')
            environment = dict(os.environ, PAPERCLIP_TEST_SERIAL=serial)
            if process.poll() is not None:
                raise ValueError('Owned emulator exited before instrumentation')
            subprocess.run(['bash', str(SCRIPTS / 'test-emulator.sh')], env=environment, check=True)
            instrumentation.healthy_emulator(serial, report, 'suite-end')
        finally:
            # Capture while our process still owns the emulator. Never inspect a
            # new process that might reuse its serial after an unexpected exit.
            if process.poll() is None:
                try:
                    diagnostics(serial, report)
                finally:
                    stop_owned(process)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('avd')
    parser.add_argument('--sdk', required=True, type=Path)
    parser.add_argument('--reports', required=True, type=Path)
    parser.add_argument('--port', type=int, default=5554)
    args = parser.parse_args()
    run(args.avd, args.sdk, args.reports, args.port)
