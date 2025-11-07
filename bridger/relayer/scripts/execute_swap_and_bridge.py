#!/usr/bin/env python3
"""Compatibility wrapper that delegates to the new relayer CLI."""
### THis is the main script that a relayer would use
from pathlib import Path
import sys

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from relayer.cli.main import main


if __name__ == "__main__":
    main()
