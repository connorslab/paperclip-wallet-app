"""Versioned, reviewed payment API installed into the pinned Jam daemon."""
import asyncio
import re
from typing import Annotated, Literal

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, model_validator
from jmwalletd.deps import get_optional_token

from .adapter import JamAdapter
from .journal import Journal, PaymentConflict
from .payments import Payments
from .hosting import install_hosting


Identifier = Annotated[str, Field(pattern=r'^[0-9a-f]{64}$')]
Outpoint = Annotated[str, Field(pattern=r'^[0-9a-f]{64}:(0|[1-9][0-9]{0,9})$')]
Sats = Annotated[int, Field(strict=True, ge=0, le=2_100_000_000_000_000)]


class Prepare(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    id: Identifier
    purpose: Literal['send', 'fund_bond', 'withdraw_bond']
    jar: Annotated[int, Field(ge=0, le=4)]
    destination: Annotated[str, Field(min_length=14, max_length=90, pattern=r'^[A-Za-z0-9]+$')]
    amount_sat: Sats
    send_max: bool
    fee_rate_millisat_vb: Annotated[int, Field(ge=1000, le=10_000_000)]
    max_fee_sat: Sats
    max_total_sat: Sats
    rbf: bool
    input_utxos: Annotated[list[Outpoint], Field(min_length=1, max_length=200)] | None = None
    bond_locktime: Annotated[int, Field(ge=1_577_836_800, le=4_099_766_400)] | None = None

    @model_validator(mode='after')
    def consistent(self):
        if self.send_max != (self.amount_sat == 0):
            raise ValueError('Send max requires zero amount; fixed sends require a positive amount')
        if self.max_fee_sat == 0 or self.max_total_sat <= self.max_fee_sat or self.amount_sat > self.max_total_sat:
            raise ValueError('Set explicit payment and fee limits')
        if (self.purpose == 'send') != (self.bond_locktime is None):
            raise ValueError('Bond actions require the reviewed unlock date')
        if self.purpose == 'withdraw_bond' and (self.jar != 0 or not self.send_max or not self.input_utxos or len(self.input_utxos) != 1):
            raise ValueError('Select one matured bond in jar 1 for full withdrawal')
        if self.input_utxos and (len(set(self.input_utxos)) != len(self.input_utxos) or
                any(int(point.split(':')[1]) > 0xffffffff for point in self.input_utxos)):
            raise ValueError('Invalid or duplicate selected input')
        return self


class Commit(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    approval: Identifier


class MutationGuard:
    """Serialize legacy mutations with review preparation; never race coin selection.

    While an intent is pending, only explicitly read-only legacy routes and
    lock/unlock are admitted. Unknown routes fail closed, including GET mutations.
    A maker/taker admitted first becomes visible to JamAdapter.idle().
    """
    def __init__(self, app, service):
        self.app, self.service = app, service

    async def __call__(self, scope, receive, send):
        if scope['type'] != 'http':
            return await self.app(scope, receive, send)
        path, method = scope['path'], scope['method']
        if re.fullmatch(r'/api/v1/wallet/[^/]+/paperclip/payments(?:/[0-9a-f]{64}(?:/(?:commit|cancel))?)?', path) or path == '/api/v1/paperclip/capabilities':
            return await self.app(scope, receive, send)
        # Lock may revoke an in-flight request immediately. Unlock is needed to
        # recover a persisted intent after a daemon restart.
        parts = path.split('/')
        wallet_route = len(parts) == 6 and parts[:4] == ['', 'api', 'v1', 'wallet']
        if wallet_route and parts[-1] in ('lock', 'unlock'):
            return await self.app(scope, receive, send)
        read_only = method == 'GET' and (path in ('/api/v1/session', '/api/v1/wallet/all') or
            (wallet_route and parts[-1] in ('display', 'utxos', 'history')))
        if not path.startswith('/api/') or read_only or method == 'OPTIONS':
            return await self.app(scope, receive, send)
        async with self.service.lock:
            if self.service.journal.pending():
                response = JSONResponse(status_code=409, content={'message':
                    'Resolve the saved Paperclip payment before changing this Jam wallet'})
                return await response(scope, receive, send)
            return await self.app(scope, receive, send)


def install(app, state):
    service = Payments(Journal(state.data_dir / 'paperclip'))
    app.state.paperclip_payments = service
    install_hosting(app, state.data_dir)
    app.add_middleware(MutationGuard, service=service)
    router = APIRouter(prefix='/api/v1')

    @app.exception_handler(PaymentConflict)
    async def conflict(_request, error):
        return JSONResponse(status_code=409, content={'message': str(error)})

    async def bounded(operation):
        try:
            async with asyncio.timeout(120):
                return await operation
        except PaymentConflict:
            raise
        except TimeoutError:
            return JSONResponse(status_code=504, content={'message':
                'Jam did not respond. Check the saved payment before taking another action.'})
        except ValueError:
            # Upstream errors can embed wallet paths, addresses and RPC data.
            return JSONResponse(status_code=409, content={'message':
                'Jam could not validate this payment. Check its address, coins, amount and fee limits.'})

    @router.get('/paperclip/capabilities')
    async def capabilities():
        return {'version': 1, 'reviewed_direct_send': True, 'bond_funding': True,
                'bond_withdrawal': True, 'coinjoin_payments': False}

    def adapter(request, walletname):
        return JamAdapter(state, get_optional_token(request), walletname)

    @router.get('/wallet/{walletname}/paperclip/payments')
    async def history(request: Request, walletname: str):
        current = adapter(request, walletname)
        return {'payments': service.journal.list(current.identity)}

    @router.post('/wallet/{walletname}/paperclip/payments')
    async def prepare(request: Request, walletname: str, body: Prepare):
        return await bounded(service.prepare(adapter(request, walletname), body.id, body.model_dump(exclude={'id'})))

    @router.post('/wallet/{walletname}/paperclip/payments/{identifier}/commit')
    async def commit(request: Request, walletname: str, identifier: Identifier, body: Commit):
        return await bounded(service.commit(adapter(request, walletname), identifier, body.approval))

    @router.get('/wallet/{walletname}/paperclip/payments/{identifier}')
    async def check(request: Request, walletname: str, identifier: Identifier):
        return await bounded(service.check(adapter(request, walletname), identifier))

    @router.post('/wallet/{walletname}/paperclip/payments/{identifier}/cancel')
    async def cancel(request: Request, walletname: str, identifier: Identifier):
        return await service.cancel(adapter(request, walletname), identifier)

    app.include_router(router)
