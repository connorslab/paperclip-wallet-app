"""Keep a native restricted RPC child alive for exactly one Jars session."""
import asyncio
from contextlib import asynccontextmanager
import json
import os
from pathlib import Path
import re
import subprocess
import sys


@asynccontextmanager
async def owned_node(root, tor, environment):
    if not os.path.lexists(root / 'node-connection.json'):
        yield None
        return
    command = [sys.executable]
    if not getattr(sys, 'frozen', False):
        command += ['-I', '-B', str(Path(__file__).resolve().parents[1] / 'desktop-entry.py')]
    command += ['--serve-node', '--data-dir', str(root)]
    if tor is not None:
        command += ['--tor-socks-port', str(tor[0])]
    process = await asyncio.create_subprocess_exec(*command, env=environment,
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL, limit=2048,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    try:
        async with asyncio.timeout(25):
            line = await process.stdout.readline()
        value = json.loads(line)
        if (set(value) != {'ready', 'port', 'username', 'password', 'connection_id'}
                or value['ready'] is not True or type(value['port']) is not int
                or not 1 <= value['port'] <= 65535 or value['username'] != 'paperclip-native'
                or not isinstance(value['password'], str) or not re.fullmatch('[0-9a-f]{64}', value['password'])
                or not isinstance(value['connection_id'], str) or not re.fullmatch('[0-9a-f]{32}', value['connection_id'])
                or process.returncode is not None):
            raise ValueError('Invalid private node readiness')
        process.node_environment = {'BITCOIN__RPC_URL': f'http://127.0.0.1:{value["port"]}',
            'BITCOIN__RPC_USER': value['username'], 'BITCOIN__RPC_PASSWORD': value['password'],
            'BITCOIN__RPC_COOKIE_FILE': '', 'BITCOIN__BACKEND_TYPE': 'descriptor_wallet'}
        yield process
    finally:
        process.stdin.close()
        try:
            async with asyncio.timeout(5):
                await process.wait()
        except TimeoutError:
            process.kill()
            await process.wait()
            raise ValueError('Node helper did not close cleanly') from None
        if process.returncode != 0:
            raise ValueError('Node helper stopped unexpectedly; check payment history')
