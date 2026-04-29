#!/usr/bin/env sh
set -eu

if [ -n "${A2O_WORKER_REQUEST_PATH:-}" ]; then
  app_root="$(ruby -rjson -e 'payload = JSON.parse(File.read(ENV.fetch("A2O_WORKER_REQUEST_PATH"))); puts payload.fetch("slot_paths").fetch("app")')"
  product_root="$app_root/reference-products/java-spring-multi-module"
else
  product_root="$(cd "$(dirname "$0")/../.." && pwd)"
fi

cd "$product_root"
mvn -q test
