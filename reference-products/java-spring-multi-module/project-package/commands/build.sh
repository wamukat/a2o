#!/usr/bin/env sh
set -eu

product_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$product_root"

mvn -q -DskipTests package
