#!/usr/bin/env sh
set -eu

fixture_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$fixture_root/repos/catalog-service"

npm test
