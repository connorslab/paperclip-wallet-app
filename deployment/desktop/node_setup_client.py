"""Native-only setup controller. Credentials travel through private child pipes."""
import json
import os
from pathlib import Path
import subprocess
import time

from managed_daemon import StartupError, private_directory
from managed_tor import ManagedTor

MAX_INPUT = 96 * 1024
MESSAGES = {
    'authentication': 'The node rejected the RPC username or password.',
    'permission': 'The node did not allow the required connection checks.',
    'wrong_chain': 'Use a synchronized XBT mainnet node.',
    'syncing': 'Your node is still synchronizing. Try again when it is ready.',
    'insecure_address': 'Use HTTPS, an onion address through Tor, or a local node.',
    'tor_required': 'Turn on Tor for an onion connection.',
    'invalid_certificate': 'Choose a public CA certificate for this node.',
    'existing_setup': 'Jars already has saved settings or wallet data. Reopen Paperclip to inspect it.',
    'unsafe_storage': 'The private Jars folder is unavailable. Your saved data was kept.',
    'storage_failure': 'The saved connection needs inspection. Reopen Paperclip before trying again.',
    'setup_in_use': 'Close the other Jars session before saving this connection.',
    'invalid_settings': 'Check the node address, username and password.',
    'redirect': 'Use the final RPC address. Redirects are not allowed.',
}


class NodeSetupClient:
    def __init__(self, runtime, root, stopping, tor_binary=None):
        self.runtime, self.root, self.stopping, self.tor_binary = runtime, Path(root), stopping, tor_binary

    def call(self, mode, payload=None, socks=None):
        python, entry = self.runtime
        command = [str(python)] + (['-I','-B',str(entry)] if entry is not None else [])
        command += [mode,'--data-dir',str(self.root/'jars')]
        if socks is not None: command += ['--tor-socks-port',str(socks)]
        data = json.dumps(payload).encode() if payload is not None else b''
        if len(data) > MAX_INPUT:
            raise StartupError('The node configuration is too large.')
        environment = {key:os.environ[key] for key in ('PATH','LANG','TMPDIR','SystemRoot','TEMP','TMP') if key in os.environ}
        process = subprocess.Popen(command,env=environment,stdin=subprocess.PIPE,stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        try:
            deadline=time.monotonic()+30
            while True:
                if self.stopping.is_set(): raise StartupError('Node setup was cancelled. Saved settings were kept.')
                if time.monotonic()>deadline: raise StartupError('Node verification timed out. Check the connection before trying again.')
                try:
                    output,_=process.communicate(data,timeout=0.1)
                    break
                except subprocess.TimeoutExpired:
                    data=None
            if len(output)>4096: raise ValueError()
            value=json.loads(output)
            if not isinstance(value,dict): raise ValueError()
            if process.returncode != 0:
                raise StartupError(MESSAGES.get(value.get('code'), 'The node could not be verified. Check its address, certificate and connection.'))
            return value
        except (OSError,ValueError):
            raise StartupError('The bundled node setup helper did not return a valid result.') from None
        finally:
            if process.poll() is None:
                process.kill(); process.wait(timeout=5)
            for stream in (process.stdin,process.stdout):
                try:stream.close()
                except OSError:pass

    def status(self):
        value=self.call('--node-status')
        if value.get('live_connection')!='not_checked' or value.get('state') not in ('saved','not_configured','existing_wallet'):
            raise StartupError('The saved Jars connection needs inspection. Your data was kept.')
        return value['state']

    def save(self, settings, progress):
        if not isinstance(settings,dict) or type(settings.get('tor',False)) is not bool:
            raise StartupError('Check the node configuration.')
        private_directory(self.root)
        tor=None
        try:
            socks=None
            if settings.get('tor',False):
                if self.tor_binary is None: raise StartupError('This package does not include Tor. Reinstall the complete Paperclip app.')
                progress('Starting Tor…')
                tor=ManagedTor(self.tor_binary,self.root/'tor')
                socks=tor.start()['socks_port']
                deadline=time.monotonic()+180
                while True:
                    if self.stopping.is_set(): raise StartupError('Node setup was cancelled.')
                    percent=tor.bootstrap_progress()
                    progress(f'Connecting to Tor · {percent}%')
                    if percent==100: break
                    if time.monotonic()>deadline: raise StartupError('Tor could not finish connecting. Try again on a working network.')
                    self.stopping.wait(0.5)
            progress('Verifying your XBT node…')
            value=self.call('--configure-node',settings,socks)
            if value.get('ready') is not True or value.get('saved') is not True or value.get('active') is not False:
                raise StartupError('The saved result is uncertain. Reopen Paperclip to inspect it.')
        finally:
            if tor is not None: tor.close()


def choose_runtime(runtime, root, tor, stopping, receive, emit):
    """Pause fresh setup before any wallet/Jars runtime or wallet journal opens."""
    if runtime is None: return None
    client=NodeSetupClient(runtime,root,stopping,tor)
    if client.status()!='not_configured': return runtime
    emit('setup',None)
    while not stopping.is_set():
        request=receive()
        if request is None: continue
        if request=={'action':'skip_jars'}: return None
        if request=={'action':'quit'}: stopping.set(); break
        if isinstance(request,dict) and set(request)=={'action','settings'} and request['action']=='configure_jars':
            try:
                client.save(request['settings'],lambda text:emit('setup_progress',text))
            except StartupError as error:
                if stopping.is_set(): break
                emit('setup_error',str(error))
                continue
            emit('setup_complete',None)
            if stopping.is_set(): break
            return runtime
        raise StartupError('The setup request was not recognized.')
    raise StartupError('Node setup was cancelled.')
