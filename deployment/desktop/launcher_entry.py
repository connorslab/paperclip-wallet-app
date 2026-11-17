"""Bundle-local entry point for Python isolated mode; ignore external module paths."""
from pathlib import Path
import runpy
import sys

sys.dont_write_bytecode = True
resources = Path(__file__).resolve().parent
sys.path.insert(0, str(resources))
runpy.run_module('launcher_bridge', run_name='__main__')
