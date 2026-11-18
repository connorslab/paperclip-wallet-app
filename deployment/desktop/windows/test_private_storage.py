"""Native Windows ACL/ownership checks in disposable unfunded directories."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import pywintypes
import win32api
import win32con
import win32file
import win32event
import win32security

from private_storage import UnsafeStorage, exclusive_file, private_directory, local_path, user_sid, ancestors, read_private_file, SessionRecord, atomic_write_private, create_private_file, prepare_child_file_owner


class PrivateStorage(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='paperclip-storage-qa-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'app'
        private_directory(self.root)

    def test_child_default_owner_changes_no_identity_privileges_or_existing_files(self):
        token = win32security.OpenProcessToken(win32api.GetCurrentProcess(),
            win32con.TOKEN_QUERY | win32con.TOKEN_ADJUST_DEFAULT)
        original = win32security.GetTokenInformation(token, win32security.TokenOwner)
        self.addCleanup(token.Close)
        self.addCleanup(lambda: win32security.SetTokenInformation(token, win32security.TokenOwner, original))
        classes = (win32security.TokenUser, win32security.TokenGroups, win32security.TokenPrivileges)
        before = [win32security.GetTokenInformation(token, kind) for kind in classes]
        dacl = win32security.GetTokenInformation(token, win32security.TokenDefaultDacl)
        original_acl = [dacl.GetAce(i) for i in range(dacl.GetAceCount())]
        existing = self.root / 'existing'
        existing.write_bytes(b'existing-fixture')
        owner = win32security.GetNamedSecurityInfo(str(existing), win32security.SE_FILE_OBJECT,
            win32security.OWNER_SECURITY_INFORMATION).GetSecurityDescriptorOwner()
        prepare_child_file_owner()
        prepare_child_file_owner()
        self.assertEqual(win32security.GetTokenInformation(token, win32security.TokenOwner), user_sid())
        self.assertEqual([win32security.GetTokenInformation(token, kind) for kind in classes], before)
        after_acl = win32security.GetTokenInformation(token, win32security.TokenDefaultDacl)
        self.assertEqual([after_acl.GetAce(i) for i in range(after_acl.GetAceCount())], original_acl)
        self.assertEqual(win32security.GetNamedSecurityInfo(str(existing), win32security.SE_FILE_OBJECT,
            win32security.OWNER_SECURITY_INFORMATION).GetSecurityDescriptorOwner(), owner)
        self.assertEqual(existing.read_bytes(), b'existing-fixture')
        if owner != user_sid():
            with self.assertRaises(UnsafeStorage), read_private_file(existing):
                self.fail('Existing foreign ownership must still be rejected')
        child = self.root / 'child-created'
        subprocess.run([sys.executable, '-c', 'from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b"child-fixture")', str(child)], check=True)
        with read_private_file(child) as reader:
            self.assertEqual(reader.read(), b'child-fixture')

    def test_private_directory_is_reusable_and_children_inherit_private_access(self):
        private_directory(self.root)
        child = self.root / 'child'
        # Elevated CI defaults ordinary mkdir's owner to Administrators. Keep
        # explicit user ownership while letting the child inherit its DACL.
        attributes = pywintypes.SECURITY_ATTRIBUTES()
        attributes.SECURITY_DESCRIPTOR.SetSecurityDescriptorOwner(user_sid(), False)
        win32file.CreateDirectory(str(child), attributes)
        private_directory(child)

    def test_existing_shared_acl_is_rejected_without_being_repaired(self):
        descriptor = win32security.GetNamedSecurityInfo(str(self.root), win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION)
        acl = descriptor.GetSecurityDescriptorDacl()
        acl.AddAccessAllowedAce(win32security.ACL_REVISION, win32con.GENERIC_READ,
            win32security.ConvertStringSidToSid('S-1-1-0'))
        win32security.SetNamedSecurityInfo(str(self.root), win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION, None, None, acl, None)
        with self.assertRaises(UnsafeStorage):
            private_directory(self.root)
        actual = win32security.GetNamedSecurityInfo(str(self.root), win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION).GetSecurityDescriptorDacl()
        self.assertEqual(actual.GetAceCount(), acl.GetAceCount())

    def test_hard_linked_lock_file_is_rejected(self):
        path = self.root / 'owner.lock'
        with exclusive_file(path):
            pass
        os.link(path, self.root / 'alias.lock')
        with self.assertRaises(UnsafeStorage), exclusive_file(path):
            self.fail('A shared file must never acquire ownership')

    def test_ancestor_handles_prevent_relocation(self):
        destination = self.root.with_name('moved')
        with ancestors(self.root / 'secret'):
            with self.assertRaises(OSError):
                self.root.rename(destination)
        self.root.rename(destination)
        destination.rename(self.root)

    def test_unrestricted_descriptor_is_rejected(self):
        win32security.SetNamedSecurityInfo(str(self.root), win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION, None, None, None, None)
        with self.assertRaises(UnsafeStorage):
            private_directory(self.root)

    def test_reparse_parent_is_rejected_before_creating_storage(self):
        junction = Path(self.temporary.name) / 'junction'
        result = subprocess.run(['cmd', '/c', 'mklink', '/J', str(junction), str(self.root)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertEqual(result.returncode, 0)
        self.addCleanup(lambda: os.rmdir(junction))
        with self.assertRaises(UnsafeStorage):
            private_directory(junction / 'unexpected')
        self.assertFalse((self.root / 'unexpected').exists())

    def test_competing_process_cannot_adopt_owned_file(self):
        path = self.root / 'owner.lock'
        code = 'from private_storage import exclusive_file; import sys\nwith exclusive_file(sys.argv[1]): pass'
        with exclusive_file(path):
            result = subprocess.run([sys.executable, '-c', code, str(path)], cwd=Path(__file__).parent,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.assertNotEqual(result.returncode, 0)
        result = subprocess.run([sys.executable, '-c', code, str(path)], cwd=Path(__file__).parent,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertEqual(result.returncode, 0)

    def test_process_death_releases_kernel_ownership(self):
        path = self.root / 'owner.lock'
        code = ('from private_storage import exclusive_file; import os, sys\n'
                'with exclusive_file(sys.argv[1]):\n'
                ' print(os.getpid(), flush=True)\n'
                ' sys.stdin.buffer.read(1)')
        process = subprocess.Popen([sys.executable, '-c', code, str(path)], cwd=Path(__file__).parent,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        owner = None
        try:
            # A Windows venv redirector can have a different PID from its Python
            # child. Terminate the process that actually holds the lock.
            pid = int(process.stdout.readline().strip())
            owner = win32api.OpenProcess(win32con.PROCESS_TERMINATE | win32con.SYNCHRONIZE, False, pid)
            with self.assertRaises(BlockingIOError), exclusive_file(path):
                self.fail('The live child must retain exclusive ownership')
            win32api.TerminateProcess(owner, 1)
            self.assertEqual(win32event.WaitForSingleObject(owner, 10000), win32event.WAIT_OBJECT_0)
            process.wait(timeout=10)
            # LockFileEx documents asynchronous OS cleanup after process death:
            # https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-lockfileex
            deadline = time.monotonic() + 5
            while True:
                try:
                    with exclusive_file(path):
                        break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        self.fail('The terminated owner retained its kernel lock')
                    time.sleep(0.02)
        finally:
            process.stdin.close()
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)
            process.stdout.close()
            if owner is not None:
                owner.Close()

    def test_nonlocal_and_ambiguous_paths_are_rejected(self):
        for path in ('relative', r'\\server\share\wallet', r'C:\wallet\..\other', r'C:\wallet:secret', r'C:\wallet.'):
            with self.subTest(path=path), self.assertRaises(UnsafeStorage):
                local_path(path)

    def record(self, path=None):
        record = SessionRecord(path or self.root / 'session.state')
        self.addCleanup(record.close)
        return record

    def test_clean_and_unclean_sessions_survive_reopen(self):
        first = self.record()
        self.assertFalse(first.begin())
        with read_private_file(self.root / 'session.state') as file:
            self.assertEqual(file.read(), SessionRecord.ACTIVE)
        first.close()  # No finish: equivalent to process death releasing handles.
        second = self.record()
        self.assertTrue(second.begin())
        second.finish(); second.close()
        third = self.record()
        self.assertFalse(third.begin())
        third.finish()

    def test_session_handle_prevents_replacement_or_relocation(self):
        record = self.record(); record.begin()
        with self.assertRaises(OSError):
            (self.root / 'session.state').rename(self.root / 'moved.state')
        with self.assertRaises(OSError):
            self.root.rename(self.root.with_name('moved'))
        record.finish()

    def test_partial_session_record_is_not_silently_reset(self):
        record = self.record(); record.begin(); record.close()
        path = self.root / 'session.state'
        path.write_bytes(b'incomplete fixture')
        second = self.record()
        with self.assertRaises(UnsafeStorage):
            second.begin()
        second.close()
        self.assertEqual(path.read_bytes(), b'incomplete fixture')

    def test_checked_reader_keeps_its_opened_identity_after_path_replacement(self):
        first = self.record(); first.begin(); first.finish(); first.close()
        other_path = self.root / 'other.state'
        second = self.record(other_path); second.begin(); second.close()
        with read_private_file(self.root / 'session.state') as file:
            # Python's legacy MoveFileEx replacement cannot overwrite an open
            # target. Exercise reader identity here; Rust's native filesystem
            # suite covers its atomic FileRenameInfoEx replacement separately.
            (self.root / 'session.state').rename(self.root / 'previous.state')
            os.replace(other_path, self.root / 'session.state')
            self.assertEqual(file.read(), SessionRecord.CLOSED)
        with read_private_file(self.root / 'session.state') as file:
            self.assertEqual(file.read(), SessionRecord.ACTIVE)

    def test_reader_rejects_missing_or_hard_linked_metadata(self):
        with self.assertRaises(FileNotFoundError), read_private_file(self.root / 'missing'):
            self.fail('Missing metadata must not be opened')
        record = self.record(); record.begin(); record.close()
        os.link(self.root / 'session.state', self.root / 'alias.state')
        with self.assertRaises(UnsafeStorage), read_private_file(self.root / 'session.state'):
            self.fail('Shared metadata must not be read')


    def test_atomic_write_preserves_old_reader_and_private_unicode_destination(self):
        path = self.root / 'wallet \U0001f512.dat'
        create_private_file(path, b'old-fixture')
        with read_private_file(path) as old:
            atomic_write_private(path, b'new-fixture')
            self.assertEqual(old.read(), b'old-fixture')
            with read_private_file(path) as new:
                self.assertEqual(new.read(), b'new-fixture')
        self.assertEqual(list(self.root.iterdir()), [path])

    def test_exclusive_creation_cannot_replace_existing_or_failed_initialization(self):
        path = self.root / 'wallet.dat'
        with patch('private_storage.win32file.FlushFileBuffers', side_effect=OSError('fixture flush failure')):
            with self.assertRaises(OSError):
                create_private_file(path, b'partial-fixture')
        with self.assertRaises(OSError):
            create_private_file(path, b'retry-fixture')
        with read_private_file(path) as reader:
            self.assertEqual(reader.read(), b'partial-fixture')

    def test_failed_flush_before_replace_keeps_original_and_removes_staging_file(self):
        path = self.root / 'wallet.dat'
        create_private_file(path, b'old-fixture')
        with patch('private_storage.win32file.FlushFileBuffers', side_effect=OSError('fixture flush failure')):
            with self.assertRaises(OSError):
                atomic_write_private(path, b'new-fixture')
        with read_private_file(path) as reader:
            self.assertEqual(reader.read(), b'old-fixture')
        self.assertEqual(list(self.root.iterdir()), [path])

    def test_failed_flush_after_replace_is_reported_with_new_state_preserved(self):
        path = self.root / 'wallet.dat'
        create_private_file(path, b'old-fixture')
        original = win32file.FlushFileBuffers
        calls = 0
        def fail_after_replace(handle):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError('fixture post-replacement flush failure')
            return original(handle)
        with patch('private_storage.win32file.FlushFileBuffers', side_effect=fail_after_replace):
            with self.assertRaises(OSError):
                atomic_write_private(path, b'new-fixture')
        with read_private_file(path) as reader:
            self.assertEqual(reader.read(), b'new-fixture')
        self.assertEqual(list(self.root.iterdir()), [path])

    def test_atomic_write_refuses_shared_destination_without_repair(self):
        path = self.root / 'wallet.dat'
        create_private_file(path, b'old-fixture')
        win32security.SetNamedSecurityInfo(str(path), win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION, None, None, None, None)
        with self.assertRaises(UnsafeStorage):
            atomic_write_private(path, b'new-fixture')
        self.assertEqual(path.read_bytes(), b'old-fixture')
        descriptor = win32security.GetNamedSecurityInfo(str(path), win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION)
        self.assertIsNone(descriptor.GetSecurityDescriptorDacl())

    def test_atomic_write_refuses_hard_linked_destination(self):
        path = self.root / 'wallet.dat'
        create_private_file(path, b'old-fixture')
        alias = self.root / 'alias.dat'
        os.link(path, alias)
        with self.assertRaises(UnsafeStorage):
            atomic_write_private(path, b'new-fixture')
        self.assertEqual(alias.read_bytes(), b'old-fixture')
        self.assertEqual(path.read_bytes(), b'old-fixture')


if __name__ == '__main__':
    unittest.main()
