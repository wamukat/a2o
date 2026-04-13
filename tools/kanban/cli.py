#!/usr/bin/env python3

from __future__ import annotations

import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from kanban.kanban_cli import main as _main


def main() -> int:
    return _main()


if __name__ == "__main__":
    sys.exit(main())
