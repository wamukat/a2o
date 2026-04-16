#!/usr/bin/env sh
set -eu

fixture_root="$(cd "$(dirname "$0")/../.." && pwd)"

(cd "$fixture_root/repos/catalog-service" && npm run build)
(cd "$fixture_root/repos/storefront" && npm run build)
