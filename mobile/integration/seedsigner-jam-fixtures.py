"""Exercise privkeyio SeedSigner's actual parser and signing policy for Jam.

Use e1351320 (same parser at 8b654423) with its pinned embit 5f700aa3.
Inputs contain only public test-key material and synthetic, unfunded outpoints.
"""
import base64
import json
from pathlib import Path

from embit import bip32, bip39
from embit.psbt import PSBT
from seedsigner.models.psbt_parser import PSBTParser
from seedsigner.models.seed import Seed


seed = Seed(mnemonic=bip39.mnemonic_from_bytes(bytes(32)).split())
root = bip32.HDKey.from_seed(seed.seed_bytes)
folder = Path('mobile/Tests/PaperclipMobileTests/Fixtures')
fixtures = json.loads((folder / 'krux-jam.json').read_text())
supported = []
for fixture in fixtures:
    request = PSBT.parse(base64.b64decode(fixture['original']))
    if fixture['locktime']:
        # The current device review parser treats P2WSH as multisig. Do not
        # bypass it by calling embit.sign_with and claiming device support.
        try:
            PSBTParser(request, seed)
        except ValueError as error:
            assert 'multisig' in str(error).lower()
        else:
            raise AssertionError('Bond review support changed; review the new signer flow')
        continue
    parser = PSBTParser(request, seed)
    assert parser.fee_amount == 1000
    assert PSBTParser.screen_sighash_type(request, seed) == (0x21, None)
    assert request.sign_with(root, sighash=PSBTParser.sighash_type(request)) == 1
    signed = PSBTParser.trim(request)
    supported.append({**fixture, 'signed': base64.b64encode(signed.serialize()).decode()})
(folder / 'seedsigner-jam.json').write_text(json.dumps(supported, indent=2) + '\n')
