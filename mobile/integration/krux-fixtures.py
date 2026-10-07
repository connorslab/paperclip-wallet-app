"""Regenerate Krux verification fixtures using its pinned embit and signing policy.

PYTHONPATH must include krux/src and krux/vendor/embit/src.
Inputs use only the public BIP39 abandon/about test seed. Never fund these keys.
"""
import base64
import json
from pathlib import Path
from embit import bip32, bip39
from embit.psbt import PSBT
from krux.blake2b import sign_psbt

root = bip32.HDKey.from_seed(bip39.mnemonic_to_seed("abandon " * 11 + "about"))
folder = Path("mobile/Tests/PaperclipMobileTests/Fixtures")
fixtures = json.loads((folder / "seedsigner.json").read_text())
for item in fixtures:
    psbt = PSBT.parse(base64.b64decode(item["original"]))
    assert sign_psbt(psbt, root) == len(psbt.inputs)
    item["signed"] = base64.b64encode(psbt.serialize()).decode()
    item.pop("ur")
(folder / "krux.json").write_text(json.dumps(fixtures, indent=2) + "\n")
