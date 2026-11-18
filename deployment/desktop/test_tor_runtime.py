"""Tor package completeness checks; synthetic executables are never launched."""
import copy
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from tor_runtime import copy_runtime, digest, target, validate


class Runtime(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='paperclip-tor-package-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'source'
        self.root.mkdir()
        (self.root / 'bin').mkdir()
        self.executable = self.root / 'bin/tor'
        self.executable.write_bytes(b'Synthetic test fixture, not executable code.')
        self.executable.chmod(0o755)
        (self.root / 'LICENSE').write_text('Synthetic license fixture')
        self.metadata = {'format':1, 'target':target(), 'version':'0.4.9.16',
            'source':'https://example.invalid/reviewed-source', 'executable':'bin/tor',
            'licenses':['LICENSE'], 'files':{'bin/tor':digest(self.executable), 'LICENSE':digest(self.root / 'LICENSE')}}
        self.save(self.metadata)

    def save(self, metadata):
        (self.root / 'runtime.json').write_text(json.dumps(metadata))

    def test_relocation_keeps_exact_inventory_and_executable(self):
        destination = Path(self.temp.name) / 'Path With Spaces' / 'Tor'
        self.assertEqual(copy_runtime(self.root, destination), self.metadata)
        shutil.rmtree(self.root)
        executable, metadata = validate(destination)
        self.assertEqual(executable, destination / 'bin/tor')
        self.assertEqual(metadata, self.metadata)
        with self.assertRaises(FileExistsError): copy_runtime(destination, destination)

    def test_damage_missing_extra_and_changed_copy_are_rejected(self):
        self.executable.write_bytes(b'changed fixture')
        with self.assertRaises(ValueError): validate(self.root)
        self.executable.unlink()
        with self.assertRaises(ValueError): validate(self.root)
        self.executable.write_bytes(b'Synthetic test fixture, not executable code.')
        self.executable.chmod(0o755)
        extra = self.root / 'unrecorded.dll'
        extra.write_bytes(b'extra')
        with self.assertRaises(ValueError): validate(self.root)
        extra.unlink()
        original_copy = shutil.copytree
        def changed(source, destination, *args, **kwargs):
            original_copy(source, destination, *args, **kwargs)
            if Path(source) == self.root:
                (destination / 'bin/tor').write_bytes(b'changed while packaging')
        with patch('tor_runtime.shutil.copytree', side_effect=changed):
            with self.assertRaises(ValueError): copy_runtime(self.root, Path(self.temp.name) / 'copy')

    def test_wrong_target_malformed_metadata_and_unsafe_paths_fail(self):
        for field, values in {
            'format':[True, 2, '1'], 'target':['foreign-architecture'], 'licenses':[[], ['missing'], ['bin/tor']],
            'source':['file:///private/source', None], 'version':['latest', None],
            'executable':['../tor', '/bin/tor', 'C:/tor', 'bin\\tor', 'CON', 'bin/tor.', 'bin/tor:stream', None],
            'files':[{}, {'bin/tor':'bad-digest'}],
        }.items():
            for value in values:
                with self.subTest(field=field, value=value):
                    metadata = copy.deepcopy(self.metadata); metadata[field] = value
                    self.save(metadata)
                    with self.assertRaises(ValueError): validate(self.root)
        for raw in [b'null', b'[]', b'{', b' ' * 131073]:
            (self.root / 'runtime.json').write_bytes(raw)
            with self.assertRaises(ValueError): validate(self.root)

    @unittest.skipIf(os.name == 'nt', 'Unix file/link test; Windows junction checks use native CI')
    def test_linked_special_and_nonexecutable_files_fail(self):
        self.executable.chmod(0o644)
        with self.assertRaises(ValueError): validate(self.root)
        self.executable.chmod(0o755)
        link = self.root / 'alias'
        link.symlink_to(self.executable)
        with self.assertRaises(ValueError): validate(self.root)
        link.unlink()
        os.mkfifo(link)
        with self.assertRaises(ValueError): validate(self.root)


if __name__ == '__main__':
    unittest.main()
