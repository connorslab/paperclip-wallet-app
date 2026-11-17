"""Bundle-local entry point for Python isolated mode; ignore external module paths."""
from pathlib import Path
import runpy
import sys

resources = Path(__file__).resolve().parent
sys.path.insert(0, str(resources))
runpy.run_path(str(resources / 'launcher_bridge.py'), run_name='__main__')
