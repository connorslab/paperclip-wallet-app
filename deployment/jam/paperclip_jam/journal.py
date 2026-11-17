"""Private, durable Jam payment intents. Signed transactions never leave this module.

The broadcast boundary is a committed SQLite transition, not an HTTP response.
An interrupted submission stays unresolved and cannot be dispatched again.
"""
from contextlib import contextmanager, ExitStack, nullcontext
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import time

if os.name == 'nt':
    from windows import private_storage as windows_storage


class PaymentConflict(ValueError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


class Journal:
    def __init__(self, directory, clock=time.time):
        self.clock = clock
        self.db = None
        self._storage = ExitStack()
        self._database_handle = None
        self._rollback_path = None
        try:
            self._open(directory)
        except BaseException:
            self.close()
            raise

    def _open(self, directory):
        directory = Path(directory)
        if '..' in directory.parts or any(p.is_symlink() for p in (directory, *directory.parents)):
            raise ValueError('Unsafe payment journal directory')
        path = directory / 'payments.sqlite'
        if os.name == 'nt':
            windows_storage.private_directory(directory)
            self._database_handle = self._storage.enter_context(windows_storage.writable_private_file(path))
            self._rollback_path = path.with_name(path.name + '-journal')
            # SQLite must recover a hot rollback journal itself. Validate before
            # opening, but allow it to remove a recovered journal before PERSIST
            # is selected. Never adopt an unreviewed WAL-mode database.
            for suffix in ('-journal', '-wal', '-shm'):
                try:
                    with windows_storage.read_private_file(path.with_name(path.name + suffix)):
                        if suffix != '-journal':
                            raise ValueError('Unexpected payment journal storage mode')
                except FileNotFoundError:
                    pass
        else:
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            os.chmod(directory, 0o700)
            fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            try:
                if not stat.S_ISREG(os.fstat(fd).st_mode):
                    raise ValueError('Payment journal must be a regular file')
                os.fchmod(fd, 0o600)
            finally:
                os.close(fd)
        self.db = sqlite3.connect(path, isolation_level=None, timeout=10, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        # Keep the Windows rollback file so every write uses explicit user ACLs
        # instead of repeatedly creating files with the token's default owner.
        mode = 'PERSIST' if os.name == 'nt' else 'DELETE'
        if self.db.execute('PRAGMA journal_mode=' + mode).fetchone()[0].upper() != mode:
            raise ValueError('Payment journal durability mode is unavailable')
        self.db.execute('PRAGMA synchronous=FULL')
        if self.db.execute('PRAGMA synchronous').fetchone()[0] != 2:
            raise ValueError('Payment journal synchronization is unavailable')
        version = self.db.execute('PRAGMA user_version').fetchone()[0]
        if version not in (0, 1):
            self.db.close()
            raise ValueError('Unsupported payment journal version')
        with self.transaction():
            self.db.execute('''CREATE TABLE IF NOT EXISTS payment (
                id TEXT PRIMARY KEY, wallet TEXT NOT NULL, request TEXT NOT NULL,
                state TEXT NOT NULL, created INTEGER NOT NULL, expires INTEGER NOT NULL,
                quote TEXT, approval TEXT, signed_tx TEXT
            )''')
            # One in-flight payment per daemon, including across process restarts.
            self.db.execute('''CREATE UNIQUE INDEX IF NOT EXISTS one_pending_payment
                ON payment((1)) WHERE state IN ('preparing','prepared','submitting','unknown')''')
            self.db.execute('PRAGMA user_version=1')

    @contextmanager
    def transaction(self):
        if os.name == 'nt':
            windows_storage.validate_handle(self._database_handle, directory=False)
        guard = windows_storage.writable_private_file(self._rollback_path) if os.name == 'nt' else nullcontext()
        with guard:
            self.db.execute('BEGIN IMMEDIATE')
            try:
                yield
                self.db.execute('COMMIT')
            except BaseException:
                self.db.execute('ROLLBACK')
                raise

    def close(self):
        try:
            if self.db is not None:
                self.db.close()
        finally:
            self._storage.close()

    def _row(self, wallet, identifier):
        row = self.db.execute('SELECT * FROM payment WHERE id=? AND wallet=?', (identifier, wallet)).fetchone()
        if row is None:
            raise PaymentConflict('Payment not found in this Jam wallet')
        return row

    @staticmethod
    def _public(row):
        return {'id': row['id'], 'state': row['state'], 'expires': row['expires'],
                'quote': json.loads(row['quote']) if row['quote'] else None,
                'approval': row['approval']}

    def status(self, wallet, identifier):
        return self._public(self._row(wallet, identifier))

    def list(self, wallet):
        rows = self.db.execute('''SELECT * FROM payment WHERE wallet=?
            ORDER BY state IN ('preparing','prepared','submitting','unknown') DESC, created DESC LIMIT 100''', (wallet,))
        return [self._public(row) for row in rows]

    def pending(self):
        return self.db.execute("SELECT 1 FROM payment WHERE state IN ('preparing','prepared','submitting','unknown') LIMIT 1").fetchone() is not None

    def reserve(self, wallet, identifier, request):
        if not re.fullmatch('[0-9a-f]{64}', identifier) or not wallet or len(wallet) > 256:
            raise ValueError('Invalid payment identity')
        encoded = canonical(request)
        if len(encoded) > 65536:
            raise ValueError('Payment request too large')
        with self.transaction():
            row = self.db.execute('SELECT * FROM payment WHERE id=?', (identifier,)).fetchone()
            if row:
                if row['wallet'] != wallet or row['request'] != encoded:
                    raise PaymentConflict('Payment identifier already belongs to different details')
                return False
            if self.pending():
                raise PaymentConflict('Resolve the saved Jam payment before preparing another')
            now = int(self.clock())
            self.db.execute('INSERT INTO payment VALUES (?,?,?,?,?,?,NULL,NULL,NULL)',
                            (identifier, wallet, encoded, 'preparing', now, now + 300))
        return True

    def prepared(self, wallet, identifier, quote, signed_tx):
        # The adapter supplies validated exact costs and the upstream-signed bytes.
        if not isinstance(signed_tx, str) or not re.fullmatch('[0-9a-f]+', signed_tx) or len(signed_tx) % 2 or len(signed_tx) > 8_000_000:
            raise ValueError('Invalid prepared transaction')
        encoded = canonical(quote)
        if len(encoded) > 65536:
            raise ValueError('Payment review too large')
        with self.transaction():
            row = self._row(wallet, identifier)
            if row['state'] != 'preparing' or self.clock() >= row['expires']:
                raise PaymentConflict('Preparation ended or expired; create a new review')
            approval = hashlib.sha256(canonical({'id': identifier, 'wallet': wallet,
                'quote': quote, 'expires': row['expires'], 'transaction': signed_tx}).encode()).hexdigest()
            self.db.execute("UPDATE payment SET state='prepared',quote=?,approval=?,signed_tx=? WHERE id=?",
                            (encoded, approval, signed_tx, identifier))
        return self.status(wallet, identifier)

    def cancel(self, wallet, identifier):
        with self.transaction():
            row = self._row(wallet, identifier)
            if row['state'] not in ('preparing', 'prepared', 'cancelled'):
                raise PaymentConflict('Submission may have reached the network; check its status')
            self.db.execute("UPDATE payment SET state='cancelled',signed_tx=NULL WHERE id=?", (identifier,))
        return self.status(wallet, identifier)

    def claim(self, wallet, identifier, approval):
        """Persist the submission boundary before returning private bytes once."""
        with self.transaction():
            row = self._row(wallet, identifier)
            if not approval or approval != row['approval']:
                raise PaymentConflict('Payment review changed; review the saved transaction')
            if row['state'] in ('submitting', 'unknown', 'submitted'):
                return None
            if row['state'] != 'prepared' or self.clock() >= row['expires']:
                raise PaymentConflict('Payment review expired or was cancelled')
            expected = hashlib.sha256(canonical({'id': identifier, 'wallet': wallet,
                'quote': json.loads(row['quote']), 'expires': row['expires'],
                'transaction': row['signed_tx']}).encode()).hexdigest()
            if expected != approval:
                raise PaymentConflict('Saved payment failed its integrity check')
            self.db.execute("UPDATE payment SET state='submitting' WHERE id=?", (identifier,))
            signed_tx = row['signed_tx']
        return signed_tx

    def finish(self, wallet, identifier, observed):
        """Only the adapter's verified network observation can resolve unknown."""
        with self.transaction():
            row = self._row(wallet, identifier)
            if row['state'] not in ('submitting', 'unknown', 'submitted'):
                raise PaymentConflict('Payment was not submitted')
            state = 'submitted' if observed or row['state'] == 'submitted' else 'unknown'
            self.db.execute('UPDATE payment SET state=?,signed_tx=NULL WHERE id=?', (state, identifier))
        return self.status(wallet, identifier)
