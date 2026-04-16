#!/usr/bin/env sh
set -eu

product_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$product_root"

python_bin="${PYTHON:-python3}"

PYTHONPATH=src "$python_bin" -m compileall -q src tests
