"""Install reviewed platform adapters into an isolated native Windows Jars venv."""
import argparse
import importlib.util
from pathlib import Path
import shutil
import sys
import sysconfig


def prepare(deployment):
    if sys.platform != 'win32' or sys.prefix == sys.base_prefix:
        raise RuntimeError('Use an isolated native Windows virtual environment')
    site = Path(sysconfig.get_path('purelib'))
    for installer, relative in [
        ('install.py','jmwalletd/app.py'),
        ('install_windows_storage.py','jmcore/secure_files.py'),
        ('install_windows_wallet_ops.py','jmwalletd/wallet_ops.py'),
        ('install_windows_metadata.py','jmcore/wallet_metadata.py'),
        ('install_windows_utxo_metadata.py','jmwallet/wallet/utxo_metadata.py'),
        ('install_windows_history.py','jmwallet/history.py'),
        ('install_windows_bond_registry.py','jmwallet/wallet/bond_registry.py'),
    ]:
        spec = importlib.util.spec_from_file_location('reviewed_installer',deployment/'jam'/installer)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        module.patch(site/relative)
    shutil.copytree(deployment/'jam/paperclip_jam',site/'paperclip_jam',ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
    (site/'windows').mkdir()
    (site/'windows/__init__.py').write_text('')
    shutil.copy2(deployment/'desktop/windows/private_storage.py',site/'windows/private_storage.py')
    print('Installed checksum-gated Jars adapters in the isolated Windows runtime.')


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--deployment',type=Path,required=True)
    prepare(parser.parse_args().deployment.resolve(strict=True))
