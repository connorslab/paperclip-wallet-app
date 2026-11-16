"""Review/commit orchestration; adapters own chain and wallet validation."""
import asyncio

from .journal import PaymentConflict


class Payments:
    def __init__(self, journal):
        self.journal = journal
        self.lock = asyncio.Lock()

    async def prepare(self, adapter, identifier, request):
        async with self.lock:
            adapter.authorize()
            if not self.journal.reserve(adapter.identity, identifier, request):
                return self.journal.status(adapter.identity, identifier)
            try:
                quote, signed = await adapter.prepare(request)
                adapter.authorize()
                return self.journal.prepared(adapter.identity, identifier, quote, signed)
            except BaseException:
                # Preparation cannot broadcast and never returns signed bytes.
                self.journal.cancel(adapter.identity, identifier)
                raise

    async def commit(self, adapter, identifier, approval):
        async with self.lock:
            adapter.authorize()
            saved = self.journal.status(adapter.identity, identifier)
            if saved['state'] in ('submitting', 'unknown', 'submitted'):
                # Even a repeated explicit HTTP commit is observation only.
                return saved
            if saved['state'] != 'prepared' or saved['approval'] != approval:
                raise PaymentConflict('Review the saved payment before submitting')
            await adapter.validate_inputs(saved['quote'])
            adapter.authorize()
            signed = self.journal.claim(adapter.identity, identifier, approval)
            if signed is None:
                return self.journal.status(adapter.identity, identifier)
            try:
                txid = await adapter.broadcast(signed, saved['quote'])
                if txid != saved['quote']['txid']:
                    raise PaymentConflict('Node returned an unexpected transaction reference; check status')
            except BaseException:
                self.journal.finish(adapter.identity, identifier, False)
                raise
            # Do not abandon this original wallet's journal if its UI locks.
            return self.journal.finish(adapter.identity, identifier, True)

    async def check(self, adapter, identifier):
        async with self.lock:
            adapter.authorize()
            saved = self.journal.status(adapter.identity, identifier)
            if saved['state'] in ('submitting', 'unknown'):
                observed = await adapter.observe(saved['quote'])
                adapter.authorize()
                return self.journal.finish(adapter.identity, identifier, observed)
            return saved

    async def cancel(self, adapter, identifier):
        async with self.lock:
            adapter.authorize()
            return self.journal.cancel(adapter.identity, identifier)
