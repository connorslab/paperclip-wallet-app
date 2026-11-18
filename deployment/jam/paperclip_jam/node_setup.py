"""Read-only native node preflight. No credentials or wallet state are persisted."""
import asyncio
import base64
from dataclasses import dataclass
import hashlib
import ipaddress
import json
import logging
import re
import ssl
from urllib.parse import urlsplit

import certifi
import httpx

MAX_INPUT = 96 * 1024
MAX_REPLY = 64 * 1024
CHECK_TIMEOUT = 20
MESSAGES = {
    'invalid_settings': 'Check the node address and RPC credentials.',
    'insecure_address': 'Use HTTPS, an onion address through Tor, or a local node.',
    'tor_required': 'Start the bundled Tor connection before checking this node.',
    'invalid_certificate': 'Use a valid public CA certificate for this node.',
    'authentication': 'The node rejected the RPC credentials.',
    'permission': 'The node did not allow the required read-only RPC checks.',
    'redirect': 'Use the final node RPC address. Redirects are not allowed.',
    'unavailable': 'The node could not be verified. Check its address, TLS certificate and connection.',
    'invalid_reply': 'The node returned an invalid RPC reply.',
    'wrong_chain': 'Connect to an activated XBT mainnet node.',
    'syncing': 'The node is still synchronizing. Check again when it is ready.',
    'existing_setup': 'This Jars directory already has configuration or wallet state. Keep its existing connection.',
    'unsafe_storage': 'The Jars directory is unavailable or is not private.',
    'setup_in_use': 'Close the running Jars service before saving its node settings.',
    'storage_failure': 'Node settings could not be saved or read safely. Check saved configuration before trying again.',
}


class NodeSetupError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(MESSAGES[code])


def onion_v3(host):
    if not re.fullmatch(r'[a-z2-7]{56}\.onion', host):
        return False
    decoded = base64.b32decode(host[:-6].upper())
    return decoded[-1] == 3 and decoded[32:34] == hashlib.sha3_256(
        b'.onion checksum' + decoded[:32] + decoded[-1:]).digest()[:2]


@dataclass(frozen=True, repr=False)
class NodeSettings:
    endpoint: str
    username: str
    password: str
    tor: bool = False
    ca_pem: str = ''

    @classmethod
    def parse(cls, value):
        if (not isinstance(value, dict) or set(value) - {'endpoint', 'username', 'password', 'tor', 'ca_pem'}
                or not {'endpoint', 'username', 'password'} <= set(value)):
            raise NodeSetupError('invalid_settings')
        settings = cls(**value)
        for item, limit in ((settings.endpoint, 2048), (settings.username, 256), (settings.password, 4096)):
            if (not isinstance(item, str) or not 0 < len(item) <= limit
                    or any(ord(char) < 32 or ord(char) == 127 for char in item)):
                raise NodeSetupError('invalid_settings')
        if ':' in settings.username or type(settings.tor) is not bool:
            raise NodeSetupError('invalid_settings')
        if not isinstance(settings.ca_pem, str) or len(settings.ca_pem) > 64 * 1024:
            raise NodeSetupError('invalid_certificate')
        try:
            address = urlsplit(settings.endpoint)
            host = address.hostname
            port = address.port
        except ValueError:
            raise NodeSetupError('invalid_settings') from None
        if (address.scheme not in ('http', 'https') or not host or address.username is not None
                or address.password is not None or address.query or address.fragment
                or address.path not in ('', '/') or (port is not None and not 1 <= port <= 65535)
                or any(char.isspace() for char in settings.endpoint) or '\\' in settings.endpoint):
            raise NodeSetupError('invalid_settings')
        onion = host.endswith('.onion')
        if onion and not onion_v3(host):
            raise NodeSetupError('invalid_settings')
        if onion and not settings.tor:
            raise NodeSetupError('tor_required')
        try:
            loopback = ipaddress.ip_address(host).is_loopback
        except ValueError:
            loopback = False
        if address.scheme == 'http' and not (loopback or onion):
            raise NodeSetupError('insecure_address')
        # A Tor exit's loopback is not this computer's local node.
        if settings.tor and loopback:
            raise NodeSetupError('invalid_settings')
        return settings

    def tls_context(self):
        # Use packaged roots, never inherited SSL_CERT_FILE/SSL_CERT_DIR.
        context = ssl.create_default_context(cafile=certifi.where())
        if self.ca_pem:
            if 'PRIVATE KEY' in self.ca_pem or '-----BEGIN CERTIFICATE-----' not in self.ca_pem:
                raise NodeSetupError('invalid_certificate')
            try:
                context.load_verify_locations(cadata=self.ca_pem)
            except (ValueError, ssl.SSLError):
                raise NodeSetupError('invalid_certificate') from None
        return context


async def verify(settings, socks_port=None):
    """Only two read-only RPCs. No wallet load, rescan, payment or retry."""
    if settings.tor and (type(socks_port) is not int or not 1 <= socks_port <= 65535):
        raise NodeSetupError('tor_required')
    proxy = f'socks5h://127.0.0.1:{socks_port}' if settings.tor else None
    context = settings.tls_context()
    try:
        async with asyncio.timeout(CHECK_TIMEOUT):
            async with httpx.AsyncClient(verify=context, trust_env=False, follow_redirects=False,
                    proxy=proxy, timeout=httpx.Timeout(10, connect=5),
                    headers={'Accept-Encoding': 'identity'},
                    auth=(settings.username, settings.password)) as client:
                async def read(method, params, identity):
                    async with client.stream('POST', settings.endpoint,
                            json={'jsonrpc': '2.0', 'id': identity, 'method': method, 'params': params}) as response:
                        if response.status_code == 401:
                            raise NodeSetupError('authentication')
                        if response.status_code == 403:
                            raise NodeSetupError('permission')
                        if 300 <= response.status_code < 400:
                            raise NodeSetupError('redirect')
                        if response.status_code != 200:
                            raise NodeSetupError('unavailable')
                        if response.headers.get('Content-Encoding', 'identity').lower() != 'identity':
                            raise NodeSetupError('invalid_reply')
                        body = bytearray()
                        async for chunk in response.aiter_bytes():
                            if len(body) + len(chunk) > MAX_REPLY:
                                raise NodeSetupError('invalid_reply')
                            body.extend(chunk)
                        try:
                            value = json.loads(body)
                        except (ValueError, UnicodeError):
                            raise NodeSetupError('invalid_reply') from None
                        if not isinstance(value, dict) or value.get('id') != identity:
                            raise NodeSetupError('invalid_reply')
                        if value.get('error') is not None:
                            raise NodeSetupError('permission')
                        if not isinstance(value.get('result'), dict):
                            raise NodeSetupError('invalid_reply')
                        return value['result']

                info = await read('getblockchaininfo', [], 'paperclip-node-chain')
                tip, height = info.get('bestblockhash'), info.get('blocks')
                difficulty = info.get('difficulty_blake2b')
                if (info.get('chain') != 'main' or type(height) is not int or height < 961640
                        or not isinstance(tip, str) or not re.fullmatch('[0-9a-f]{64}', tip)
                        or type(difficulty) not in (int, float) or not 0 < difficulty <= 1e300):
                    raise NodeSetupError('wrong_chain')
                if info.get('initialblockdownload') is not False:
                    raise NodeSetupError('syncing')
                header = await read('getblockheader', [tip, True], 'paperclip-node-header')
                version = header.get('header_version')
                if (type(version) is not int or version < 2 or header.get('hash') != tip
                        or type(header.get('height')) is not int or header['height'] != height):
                    raise NodeSetupError('wrong_chain')
                return {'ready': True, 'network': 'main', 'height': height, 'pruned': info.get('pruned') is True}
    except (httpx.HTTPError, OSError, TimeoutError):
        raise NodeSetupError('unavailable') from None


def check_pipe(source, destination, socks_port=None, *, admit=None, save=None):
    """One bounded private stdin document; stdout contains only a public result."""
    logging.disable(logging.CRITICAL)
    try:
        if admit is not None:
            admit()
        encoded = source.read(MAX_INPUT + 1)
        if len(encoded) > MAX_INPUT:
            raise NodeSetupError('invalid_settings')
        try:
            settings = NodeSettings.parse(json.loads(encoded))
        except (ValueError, UnicodeError, TypeError):
            raise NodeSetupError('invalid_settings') from None
        result = asyncio.run(verify(settings, socks_port))
        if save is not None:
            result.update(save(settings))
    except NodeSetupError as error:
        result = {'ready': False, 'code': error.code, 'message': str(error)}
    except Exception:
        result = {'ready': False, 'code': 'unavailable', 'message': MESSAGES['unavailable']}
    destination.write(json.dumps(result) + '\n')
    destination.flush()
    return 0 if result['ready'] else 2


def report_failure(destination, code):
    destination.write(json.dumps({'ready': False, 'code': code, 'message': MESSAGES[code]}) + '\n')
    destination.flush()
    return 2
