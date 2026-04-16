#!/usr/bin/env sh
set -eu

product_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$product_root"

test -f go.mod
echo "go-api-cli workspace ready: $product_root"
