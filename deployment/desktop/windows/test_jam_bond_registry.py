"""Pinned bond metadata persistence on Windows; public synthetic bonds only."""
import argparse
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch as mock_patch

import win32security

from install_windows_bond_registry import patch
from paperclip_jam import windows_storage

UPSTREAM = None


class BondRegistry(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name).resolve();self.data=self.root/'private'
        self.source=self.root/'bond_registry.py';self.source.write_bytes(UPSTREAM.read_bytes());patch(self.source)
        spec=importlib.util.spec_from_file_location('reviewed_bond_registry',self.source)
        self.api=importlib.util.module_from_spec(spec)
        with mock_patch.dict(sys.modules,{spec.name:self.api}):spec.loader.exec_module(self.api)

    def bond(self,n):
        return self.api.FidelityBondInfo(address=f'synthetic-address-{n}',locktime=1900000000,locktime_human='synthetic',
            index=n,path=f'm/84h/0h/0h/2/{n}',pubkey='02'+'01'*32,witness_script_hex='00',network='regtest',created_at='2026-01-01')

    def test_rewrite_and_reopen_keep_separate_wallets(self):
        first=self.api.BondRegistry(bonds=[self.bond(1)]);second=self.api.BondRegistry(bonds=[self.bond(2)])
        self.api.save_registry(first,self.data,'12345678');self.api.save_registry(second,self.data,'87654321')
        self.api.save_registry(first,self.data,'12345678')
        for fingerprint,expected in [('12345678',1),('87654321',2)]:
            loaded=self.api.load_registry(self.data,fingerprint,allow_legacy_fallback=False,fail_closed=True)
            self.assertEqual([b.index for b in loaded.bonds],[expected])
            windows_storage.ensure_private_file(self.api.get_registry_path(self.data,fingerprint))

    def test_legacy_migration_copies_only_verified_bonds(self):
        self.api.save_registry(self.api.BondRegistry(bonds=[self.bond(1),self.bond(2)]),self.data)
        count=self.api.migrate_legacy_registry(self.data,'12345678',lambda bond:bond.index==1)
        self.assertEqual(count,1)
        self.assertEqual([b.index for b in self.api.load_registry(self.data,'12345678',allow_legacy_fallback=False).bonds],[1])
        self.assertEqual([b.index for b in self.api.load_registry(self.data).bonds],[2])
        self.assertEqual(self.api.migrate_legacy_registry(self.data,'12345678',lambda bond:True),0)

    def test_corrupt_registry_fails_closed_and_is_preserved(self):
        path=self.api.get_registry_path(self.data,'12345678')
        windows_storage.atomic_write_private(path,b'{broken')
        with self.assertRaises(ValueError):self.api.load_registry(self.data,'12345678',fail_closed=True)
        self.assertEqual(windows_storage.read_private_file(path),b'{broken')

    def test_unsafe_registry_is_not_repaired_or_overwritten(self):
        registry=self.api.BondRegistry(bonds=[self.bond(1)]);self.api.save_registry(registry,self.data,'12345678')
        path=self.api.get_registry_path(self.data,'12345678');before=path.read_bytes()
        win32security.SetNamedSecurityInfo(str(path),win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION,None,None,None,None)
        with self.assertRaises(ValueError):self.api.load_registry(self.data,'12345678',fail_closed=True)
        with self.assertRaises(ValueError):self.api.save_registry(registry,self.data,'12345678')
        self.assertEqual(path.read_bytes(),before)
        self.assertIsNone(win32security.GetNamedSecurityInfo(str(path),win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION).GetSecurityDescriptorDacl())

    def test_changed_source_is_rejected_without_modification(self):
        original=UPSTREAM.read_bytes()+b'\n# changed\n';self.source.write_bytes(original)
        with self.assertRaises(ValueError):patch(self.source)
        self.assertEqual(self.source.read_bytes(),original)


if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--upstream',type=Path,required=True)
    args,remaining=parser.parse_known_args();UPSTREAM=args.upstream.resolve(strict=True)
    unittest.main(argv=[__file__]+remaining)
