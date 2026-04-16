#!/usr/bin/env sh
set -eu

product_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$product_root"

test -f pyproject.toml
echo "python-service workspace ready: $product_root"
