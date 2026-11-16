"""Add the isolated Jam and RPC-filter companions to an Umbrel candidate."""
import json
from pathlib import Path
import re


def add_bundled_jam(directory, image, app):
    if not re.fullmatch(r'[a-z0-9][a-z0-9.:/_-]*:[A-Za-z0-9_.-]+@sha256:[0-9a-f]{64}', image):
        raise ValueError('Jam needs its tested, immutable multi-architecture companion image')
    directory = Path(directory)
    compose = json.loads((directory / 'docker-compose.yml').read_text())
    services = compose['services']
    common = {'image': image, 'user': '1000:1000', 'restart': 'unless-stopped',
        'stop_grace_period': '2m', 'security_opt': ['no-new-privileges:true'], 'cap_drop': ['ALL']}
    node_environment = {'PYTHONUNBUFFERED': '1'}
    for provider in ('BITCOIN', 'KNOTS_BLAKE2B', 'BITCOIN_KNOTS'):
        for name, suffix in (('IP', 'NODE_IP'), ('PORT', 'RPC_PORT'), ('USER', 'RPC_USER'), ('PASS', 'RPC_PASS')):
            node_environment[f'NODE_{provider}_{name}'] = '${APP_' + provider + '_' + suffix + ':-}'
    services['jam-rpc'] = {**common,
        'entrypoint': ['/opt/venv/bin/python', '/usr/local/lib/jm-xbt/paperclip-rpc-entry.py'],
        'environment': node_environment,
        'volumes': ['${APP_DATA_DIR}/jam-rpc:/rpc-filter']}
    services['jam'] = {**common, 'depends_on': ['jam-rpc'],
        'environment': {'JMWALLETD_HOST': '127.0.0.1', 'JM_XBT_RPC_FILTER': 'external',
            'BITCOIN_RPC_URL': 'http://' + app + '_jam-rpc_1:28187',
            'BITCOIN_RPC_COOKIE': '/run/jm-xbt-rpc/client.cookie',
            'PAPERCLIP_JAM_PUBLIC_CERT_FILE': '/run/paperclip-jam-public/cert.pem'},
        'volumes': ['${APP_DATA_DIR}/jam:/data', '${APP_DATA_DIR}/jam-rpc:/run/jm-xbt-rpc:ro',
            '${APP_DATA_DIR}/jam-public:/run/paperclip-jam-public']}
    # Share only the network namespace, never Jam's wallet files or TLS key.
    # Its loopback HTTPS certificate remains valid without disabling hostname checks.
    wallet = services['wallet']
    wallet['network_mode'] = 'service:jam'
    wallet['depends_on'] = ['jam']
    wallet['volumes'].append('${APP_DATA_DIR}/jam-public:/run/paperclip-jam-public:ro')
    wallet['environment'].update(BARKD_JOINBLAKET_URL='https://localhost:28183',
        BARKD_JOINBLAKET_CA_FILE='/run/paperclip-jam-public/cert.pem')
    services['app_proxy']['environment']['APP_HOST'] = app + '_jam_1'
    (directory / 'docker-compose.yml').write_text(json.dumps(compose, indent=2) + '\n')
    manifest = json.loads((directory / 'umbrel-app.yml').read_text())
    manifest['dependencies'] = ['bitcoin']
    manifest['description'] += ' Includes a separate JoinBlaket/Jam wallet with five jars. Select a BLAKE2b node; its chain is checked before Jam starts. Backups must include data, jam, jam-rpc and jam-public.'
    (directory / 'umbrel-app.yml').write_text(json.dumps(manifest, indent=2) + '\n')
    for volume in ('jam', 'jam-rpc', 'jam-public'):
        (directory / volume).mkdir()
        (directory / volume / '.gitkeep').touch()
