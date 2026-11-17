"""Native Windows ACL/ownership checks in disposable unfunded directories."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import pywintypes
import win32con
import win32file
import win32security

from private_storage import UnsafeStorage, exclusive_file, private_directory, local_path, user_sid, ancestors, read_private_file, SessionRecord


class PrivateStorage(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='paperclip-storage-qa-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'app'
        private_directory(self.root)

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
        code = ('from private_storage import exclusive_file; import sys\n'
                'with exclusive_file(sys.argv[1]):\n'
                ' print("ready", flush=True)\n'
                ' sys.stdin.buffer.read(1)')
        process = subprocess.Popen([sys.executable, '-c', code, str(path)], cwd=Path(__file__).parent,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            self.assertEqual(process.stdout.readline(), b'ready\r\n')
            process.kill()
            process.wait(timeout=10)
            with exclusive_file(path):
                pass
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)
            process.stdin.close(); process.stdout.close()

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


if __name__ == '__main__':
    unittest.main()
