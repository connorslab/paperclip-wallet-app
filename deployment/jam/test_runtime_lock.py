"""Runtime admission with real OS locks and an unfunded application fixture."""
from contextlib import asynccontextmanager
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from paperclip_jam.hosting import install_hosting

if os.name == 'nt':
    from windows.private_storage import private_directory


class RuntimeLock(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        if os.name == 'nt':
            private_directory(self.root / 'paperclip')
        else:
            (self.root / 'paperclip').mkdir(mode=0o700)

    def application(self, events, fail=False):
        @asynccontextmanager
        async def original(app):
            events.append('entered')
            if fail:
                raise RuntimeError('fixture startup failure')
            try:
                yield
            finally:
                events.append('closed')
        app = SimpleNamespace(router=SimpleNamespace(lifespan_context=original))
        install_hosting(app, self.root)
        return app

    async def test_competing_runtime_does_not_enter_upstream_lifespan(self):
        events, other_events = [], []
        app = self.application(events)
        other = self.application(other_events)
        async with app.router.lifespan_context(app):
            with self.assertRaises(OSError):
                async with other.router.lifespan_context(other):
                    self.fail('Competing runtime entered upstream state')
            self.assertEqual(other_events, [])
            self.assertEqual(events, ['entered'])
        self.assertEqual(events, ['entered', 'closed'])
        async with other.router.lifespan_context(other):
            self.assertEqual(other_events, ['entered'])
        self.assertEqual(other_events, ['entered', 'closed'])

    async def test_failed_startup_releases_runtime_lock_for_explicit_retry(self):
        app = self.application([], fail=True)
        with self.assertRaisesRegex(RuntimeError, '^fixture startup failure$'):
            async with app.router.lifespan_context(app):
                self.fail('Fixture startup should fail')
        events = []
        retry = self.application(events)
        async with retry.router.lifespan_context(retry):
            self.assertEqual(events, ['entered'])
        self.assertEqual(events, ['entered', 'closed'])


if __name__ == '__main__':
    unittest.main()
