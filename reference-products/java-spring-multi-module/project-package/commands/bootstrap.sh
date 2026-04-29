#!/usr/bin/env sh
set -eu

product_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$product_root"

test -f pom.xml
test -f utility-lib/pom.xml
test -f web-app/pom.xml
echo "java-spring-multi-module workspace ready: $product_root"
