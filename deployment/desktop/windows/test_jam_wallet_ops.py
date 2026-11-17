"""Native locks and cancellation in pinned Jam lifecycle functions, without keys.

Only the reservation and blocking-worker functions are compiled from the patched
upstream source. This does not substitute for wallet creation/crypto acceptance.
"""
import argparse
import ast
import asyncio
from collections.abc import Callable, Iterator
from contextlib import contextmanager
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from typing import ParamSpec, TypeVar
import unittest

import win32security

from install_windows_wallet_ops import patch
from paperclip_jam.windows_storage import ensure_private_directory, create_private_file_exclusive

UPSTREAM = None


def load_functions(source):
    tree = ast.parse(source.read_text())
    names = {'_reserve_wallet_path', '_run_wallet_file_operation'}
    selected = [node for node in tree.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in names]
    selected.extend(node for node in tree.body if isinstance(node, ast.If) and any(isinstance(child, ast.ImportFrom) and child.module == 'paperclip_jam.windows_wallet_ops' for child in node.body))
    if len(selected) != 3:
        raise AssertionError('Pinned lifecycle functions or native dispatch missing')
    env = dict(globals(), P=ParamSpec('P'), T=TypeVar('T'))
    exec(compile(ast.Module(body=selected, type_ignores=[]), str(source), 'exec'), env)
    return env['_reserve_wallet_path'], env['_run_wallet_file_operation']


class WalletOperations(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'wallet_ops.py'
        self.source.write_bytes(UPSTREAM.read_bytes())
        patch(self.source)
        self.reserve, self.worker = load_functions(self.source)
        self.wallet = self.root / 'private' / 'wallet.jmdat'

    def test_same_directory_is_exclusive_and_existing_wallet_is_preserved(self):
        with self.reserve(self.wallet):
            with self.assertRaises(FileExistsError):
                with self.reserve(self.wallet.with_name('other.jmdat')):
                    self.fail('Concurrent creation admitted')
        with self.reserve(self.wallet):
            create_private_file_exclusive(self.wallet, b'unfunded-fixture')
        with self.assertRaises(FileExistsError):
            with self.reserve(self.wallet):
                self.fail('Existing wallet admitted')
        self.assertEqual(self.wallet.read_bytes(), b'unfunded-fixture')

    async def test_cancellation_retains_reservation_until_writer_finishes(self):
        started, finish = threading.Event(), threading.Event()
        def writer():
            started.set()
            if not finish.wait(10):
                raise TimeoutError('Fixture writer did not finish')
        async def lifecycle():
            with self.reserve(self.wallet):
                await self.worker(writer)
        task = asyncio.create_task(lifecycle())
        try:
            self.assertTrue(await asyncio.to_thread(started.wait, 5))
            task.cancel()
            await asyncio.sleep(0)
            self.assertFalse(task.done())
            with self.assertRaises(FileExistsError):
                with self.reserve(self.wallet):
                    self.fail('Cancellation released an active writer')
        finally:
            finish.set()
            with self.assertRaises(asyncio.CancelledError):
                await task
        with self.reserve(self.wallet):
            pass

    def test_crash_releases_kernel_reservation_without_deleting_lock_file(self):
        child = subprocess.Popen([sys.executable, __file__, '--upstream', str(UPSTREAM), '--hold', str(self.wallet)], stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), 'held')
            with self.assertRaises(FileExistsError):
                with self.reserve(self.wallet):
                    self.fail('Another process owns this wallet lifecycle')
        finally:
            child.kill()
            child.wait(timeout=10)
            child.stdout.close()
        with self.reserve(self.wallet):
            self.assertTrue((self.wallet.parent / '.wallet-operation.lock').exists())

    def test_failed_creation_releases_reservation_for_explicit_retry(self):
        with self.assertRaisesRegex(RuntimeError, 'fixture'):
            with self.reserve(self.wallet):
                raise RuntimeError('fixture')
        with self.reserve(self.wallet):
            pass

    def test_writer_error_is_not_relabelled_as_lock_contention(self):
        with self.assertRaisesRegex(BlockingIOError, '^fixture writer failure$'):
            with self.reserve(self.wallet):
                raise BlockingIOError('fixture writer failure')
        with self.reserve(self.wallet):
            pass

    def test_unsafe_lock_permissions_are_not_repaired(self):
        with self.reserve(self.wallet):
            pass
        lock = self.wallet.parent / '.wallet-operation.lock'
        win32security.SetNamedSecurityInfo(str(lock), win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION, None, None, None, None)
        with self.assertRaises(ValueError):
            with self.reserve(self.wallet):
                self.fail('Unsafe lock admitted')
        self.assertIsNone(win32security.GetNamedSecurityInfo(str(lock), win32security.SE_FILE_OBJECT,
            win32security.DACL_SECURITY_INFORMATION).GetSecurityDescriptorDacl())

    def test_junction_wallet_directory_is_not_followed(self):
        ensure_private_directory(self.wallet.parent)
        alias = self.root / 'alias'
        result = subprocess.run(['cmd', '/C', 'mklink', '/J', str(alias), str(self.wallet.parent)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertEqual(result.returncode, 0)
        try:
            with self.assertRaises(ValueError):
                with self.reserve(alias / 'wallet.jmdat'):
                    self.fail('Alias admitted')
            self.assertFalse((self.wallet.parent / '.wallet-operation.lock').exists())
        finally:
            alias.rmdir()

    def test_unreviewed_source_is_rejected_unchanged(self):
        original = UPSTREAM.read_bytes() + b'\n# changed\n'
        self.source.write_bytes(original)
        with self.assertRaises(ValueError):
            patch(self.source)
        self.assertEqual(self.source.read_bytes(), original)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--upstream', type=Path, required=True)
    parser.add_argument('--hold', type=Path)
    args, remaining = parser.parse_known_args()
    UPSTREAM = args.upstream.resolve(strict=True)
    if args.hold:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'wallet_ops.py'
            source.write_bytes(UPSTREAM.read_bytes())
            patch(source)
            reserve, _ = load_functions(source)
            with reserve(args.hold):
                print('held', flush=True)
                threading.Event().wait(30)
    else:
        unittest.main(argv=[__file__] + remaining)
