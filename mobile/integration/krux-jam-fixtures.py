"""Public, unfunded interoperability vectors from pinned Jam and Krux code.

Requires Krux 82036749, its embit 087d020f and JoinBlaket 40a29ae4 on PYTHONPATH.
Exercises the signing implementation, not camera or physical-device review.
"""
import base64
from datetime import datetime, timezone
import json
from pathlib import Path

from embit import bip32, bip39, script
from embit.psbt import PSBT, DerivationPath
from embit.transaction import Transaction, TransactionInput, TransactionOutput
from jmcore.btc_script import mk_freeze_script
from jmcore.timenumber import timestamp_to_timenumber
from krux.blake2b import sign_psbt


root = bip32.HDKey.from_seed(bip39.mnemonic_to_seed(bip39.mnemonic_from_bytes(bytes(32))))
destination = script.p2wpkh(root.derive("m/84h/0h/10h/0/0").key.get_public_key())
fixtures = []
for name, jar, year in [(f'jar-{jar + 1}', jar, None) for jar in range(5)] + [('fund-bond-2040', 0, None), ('bond-2030', 0, 2030), ('bond-2040', 0, 2040)]:
    locktime = int(datetime(year, 1, 1, tzinfo=timezone.utc).timestamp()) if year else 0
    suffix = f'2/{timestamp_to_timenumber(locktime)}' if year else '0/0'
    path = bip32.parse_path(f'm/84h/0h/{jar}h/{suffix}')
    pubkey = root.derive(path).key.get_public_key()
    witness = script.Script(mk_freeze_script(pubkey.sec().hex(), locktime)) if year else None
    spent = script.p2wsh(witness) if year else script.p2wpkh(pubkey)
    parent = Transaction(vin=[TransactionInput(bytes.fromhex('11' * 32), 0)],
        vout=[TransactionOutput(100_000, spent)])
    target = destination
    if name == 'fund-bond-2040':
        target = script.p2wsh(script.Script(mk_freeze_script(
            root.derive('m/84h/0h/10h/2/240').key.get_public_key().sec().hex(),
            int(datetime(2040, 1, 1, tzinfo=timezone.utc).timestamp()))))
    request = PSBT(Transaction(version=2, locktime=locktime,
        vin=[TransactionInput(parent.txid(), 0, sequence=0xfffffffe)],
        vout=[TransactionOutput(99_000, target)]))
    inp = request.inputs[0]
    inp.non_witness_utxo = parent
    inp.witness_utxo = parent.vout[0]
    inp.witness_script = witness
    inp.bip32_derivations[pubkey] = DerivationPath(root.my_fingerprint, path)
    inp.sighash_type = 0x21
    original = base64.b64encode(request.serialize()).decode()
    assert sign_psbt(request, root) == 1
    fixtures.append({'name': name, 'jar': jar, 'locktime': locktime, 'original': original,
        'signed': base64.b64encode(request.serialize()).decode()})
Path('mobile/Tests/PaperclipMobileTests/Fixtures/krux-jam.json').write_text(json.dumps(fixtures, indent=2) + '\n')
