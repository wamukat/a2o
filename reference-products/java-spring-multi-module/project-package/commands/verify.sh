#!/usr/bin/env sh
set -eu

if [ -n "${A2O_WORKER_REQUEST_PATH:-}" ]; then
  product_root="$(ruby -rjson -e '
    payload = JSON.parse(File.read(ENV.fetch("A2O_WORKER_REQUEST_PATH")))
    paths = payload.fetch("slot_paths")
    app = paths["app"]
    lib = paths["lib"]
    candidates = []
    candidates << File.dirname(app) if app && File.basename(app) == "web-app"
    candidates << File.dirname(lib) if lib && File.basename(lib) == "utility-lib"
    paths.each_value do |path|
      candidates << path
      candidates << File.join(path, "reference-products/java-spring-multi-module")
    end
    found = candidates.compact.find { |path| File.exist?(File.join(path, "pom.xml")) && File.exist?(File.join(path, "utility-lib/pom.xml")) && File.exist?(File.join(path, "web-app/pom.xml")) }
    abort("Java sample product root not found from slot_paths=#{paths.inspect}") unless found
    puts found
  ')"
else
  product_root="$(cd "$(dirname "$0")/../.." && pwd)"
fi

cd "$product_root"
mvn -q test
