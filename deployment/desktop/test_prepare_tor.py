"""Pinned archive preparation rejects corruption and unsafe extraction."""
import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import prepare_tor
from tor_runtime import validate


class Preparation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='paperclip-tor-preparation-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'fixture.tar.gz'
        self.output = self.root / 'output'
        self.record = {'sha256':'', 'source':'https://example.invalid/fixture',
                       'version':'0.4.9.16', 'executable':'tor/tor'}
        # Pure archive tests do not run platform signing or executable code.
        self.platform = patch.object(prepare_tor.sys, 'platform', 'linux')
        self.platform.start(); self.addCleanup(self.platform.stop)

    def write(self, extra=None):
        with tarfile.open(self.archive, 'w:gz') as tar:
            for name, body in [('tor/tor', b'Synthetic non-executable fixture'),
                               ('docs/tor.txt', b'Tor license fixture'), ('docs/libevent.txt', b'Event license fixture'),
                               ('docs/openssl.txt', b'TLS license fixture')]:
                member = tarfile.TarInfo(name); member.size = len(body); member.mode = 0o755
                tar.addfile(member, io.BytesIO(body))
            if extra: tar.addfile(extra, io.BytesIO(b'x' * extra.size) if extra.isfile() else None)
        self.record['sha256'] = hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def prepare(self):
        return prepare_tor.prepare(self.archive, self.output, self.record)

    def test_exact_pinned_archive_preserves_input_and_licenses(self):
        self.write()
        before = self.archive.read_bytes()
        with patch.object(prepare_tor.subprocess, 'run') as run:
            metadata = self.prepare()
            run.assert_not_called()
        self.assertEqual(self.archive.read_bytes(), before)
        self.assertEqual(validate(self.output)[1], metadata)
        self.assertEqual(len(metadata['licenses']), 3)
        with self.assertRaises(ValueError): self.prepare()
        self.assertEqual(validate(self.output)[1], metadata)

    def test_wrong_hash_does_not_extract_or_launch(self):
        self.write(); self.record['sha256'] = '0' * 64
        with patch.object(prepare_tor, 'unpack') as unpack:
            with self.assertRaises(ValueError): self.prepare()
            unpack.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_unsafe_names_links_duplicates_and_special_files_leave_no_output(self):
        sentinel = self.root / 'sentinel'; sentinel.write_bytes(b'unchanged')
        entries = []
        for name in ('../sentinel', '/absolute', 'C:/drive', 'tor\\outside', 'docs/CON', 'tor/tor', 'TOR/TOR'):
            entries.append(tarfile.TarInfo(name))
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE):
            entry = tarfile.TarInfo('linked'); entry.type = kind; entry.linkname = '../sentinel'; entries.append(entry)
        for entry in entries:
            with self.subTest(entry=entry.name, kind=entry.type):
                self.write(entry)
                with self.assertRaises((ValueError, OSError)): self.prepare()
                self.assertFalse(self.output.exists())
                self.assertEqual(sentinel.read_bytes(), b'unchanged')
                self.assertFalse(list(self.root.glob('.paperclip-tor-*')))

    def test_extraction_bounds_and_missing_licenses_fail_closed(self):
        self.write()
        for limit in ('MAX_MEMBERS', 'MAX_EXPANDED'):
            with patch.object(prepare_tor, limit, 1):
                with self.assertRaises(ValueError): self.prepare()
            self.assertFalse(self.output.exists())
        original = prepare_tor.unpack
        def missing(file, output):
            original(file, output)
            (output / 'docs/openssl.txt').unlink()
        with patch.object(prepare_tor, 'unpack', side_effect=missing):
            with self.assertRaises(ValueError): self.prepare()
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
