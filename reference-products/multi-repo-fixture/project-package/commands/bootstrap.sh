#!/usr/bin/env sh
set -eu

fixture_root="$(cd "$(dirname "$0")/../.." && pwd)"

test -f "$fixture_root/repos/catalog-service/package.json"
test -f "$fixture_root/repos/storefront/package.json"
echo "multi-repo fixture workspace ready: $fixture_root"
