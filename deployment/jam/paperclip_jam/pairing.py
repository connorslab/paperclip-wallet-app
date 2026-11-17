"""Host-only scoped delegation. Ordinary Jam JWT lifetimes are unchanged.

Delegation is memory-only, bound to the live wallet object/session and expires in
30 days. Lock/restart invalidates it. The host issues/revokes individual phone
grants; this credential never crosses its private proxy boundary.
"""
import secrets
import re
import time

from fastapi.responses import JSONResponse


class Delegations:
    def __init__(self, state):
        self.state = state
        self.record = None

    def current(self):
        record = self.record
        return record is not None and record['wallet'] is self.state.wallet_service and record['name'] == self.state.wallet_name and \
            record['generation'] == self.state.wallet_generation and \
            record['key'] == self.state.token_authority._access_key and record['expires'] > time.time()

    def issue(self, adapter):
        adapter.authorize()
        if not self.current():
            self.record = {'wallet': adapter.wallet, 'name': adapter.walletname,
                           'generation': adapter.generation,
                           'key': self.state.token_authority._access_key,
                           'token': 'pjh1_' + secrets.token_hex(32),
                           'expires': int(time.time()) + 30 * 86400, 'identity': adapter.identity}
        record = self.record
        return {'token': record['token'], 'expires': record['expires'],
                'wallet': record['name'], 'identity': record['identity']}

    def access(self, token, path, method):
        if not self.current() or not secrets.compare_digest(token, self.record['token']):
            return None
        prefix = '/api/v1/wallet/' + self.record['name'] + '/'
        if method == 'GET':
            allowed = bool(re.fullmatch(r'/api/v1/paperclip/market/[0-9]{1,16}', path)) or path == '/api/v1/session' or path in [prefix + suffix for suffix in (
                'utxos', 'paperclip/identity', 'paperclip/payments', 'maker/stop')]
            if path.startswith(prefix):
                suffix = path[len(prefix):].split('/')
                allowed |= len(suffix) == 3 and suffix[:2] == ['address', 'new'] and suffix[2] in ('0', '1', '2', '3', '4')
                allowed |= len(suffix) == 4 and suffix[:3] == ['address', 'timelock', 'new'] and len(suffix[3]) == 7 and '/' not in suffix[3]
                allowed |= len(suffix) == 3 and suffix[:2] == ['paperclip', 'payments'] and len(suffix[2]) == 64 and all(c in '0123456789abcdef' for c in suffix[2])
        else:
            allowed = method == 'POST' and path == prefix + 'maker/start'
        if not allowed:
            return None
        # Produce an ordinary short JWT only inside the scoped request. It is
        # checked again by the original route, including after its async work.
        return self.state.token_authority.issue(self.record['name'], rotate_refresh=False).token


class DelegationGuard:
    def __init__(self, app, delegations):
        self.app, self.delegations = app, delegations

    async def __call__(self, scope, receive, send):
        headers = scope.get('headers', [])
        delegated = [value for key, value in headers if key.lower() == b'authorization' and value.startswith(b'Bearer pjh1_')]
        if not delegated:
            return await self.app(scope, receive, send)
        access = None
        if scope['type'] == 'http' and len([1 for key, _ in headers if key.lower() in (b'authorization', b'x-jm-authorization')]) == 1:
            try:
                access = self.delegations.access(delegated[0][7:].decode('ascii'), scope['path'], scope['method'])
            except (UnicodeError, ValueError):
                pass
        if access is None:
            if scope['type'] == 'websocket':
                return await send({'type': 'websocket.close', 'code': 4401})
            return await JSONResponse(status_code=401, content={'message': 'Host pairing session is unavailable or operation is not permitted'})(scope, receive, send)
        scope = dict(scope, headers=[(key, value) for key, value in headers if key.lower() != b'authorization'] +
                     [(b'authorization', ('Bearer ' + access).encode('ascii'))])
        return await self.app(scope, receive, send)
