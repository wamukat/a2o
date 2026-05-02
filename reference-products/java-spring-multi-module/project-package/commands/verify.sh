#!/usr/bin/env sh
set -eu

if [ -n "${A2O_WORKER_REQUEST_PATH:-}" ]; then
  eval "$(ruby -rjson -rshellwords -e '
    payload = JSON.parse(File.read(ENV.fetch("A2O_WORKER_REQUEST_PATH")))
    paths = payload.fetch("slot_paths")
    app = paths["app"]
    lib = paths["lib"]
    if app && lib && File.exist?(File.join(app, "pom.xml")) && File.exist?(File.join(lib, "pom.xml"))
      puts "verification_mode=split_slots"
      puts "app_root=#{app.shellescape}"
      puts "lib_root=#{lib.shellescape}"
      exit
    end
    candidates = []
    candidates << File.dirname(app) if app && File.basename(app) == "web-app"
    candidates << File.dirname(lib) if lib && File.basename(lib) == "utility-lib"
    paths.each_value do |path|
      candidates << path
      candidates << File.join(path, "reference-products/java-spring-multi-module")
    end
    found = candidates.compact.find { |path| File.exist?(File.join(path, "pom.xml")) && File.exist?(File.join(path, "utility-lib/pom.xml")) && File.exist?(File.join(path, "web-app/pom.xml")) }
    abort("Java sample product root not found from slot_paths=#{paths.inspect}") unless found
    puts "verification_mode=reactor"
    puts "product_root=#{found.shellescape}"
  ')"
else
  verification_mode=reactor
  product_root="$(cd "$(dirname "$0")/../.." && pwd)"
fi

package_product_root="$(cd "$(dirname "$0")/../.." && pwd)"

case "$verification_mode" in
  split_slots)
    maven_repo="${MAVEN_REPO_LOCAL:-$PWD/.work/m2/repository}"
    mvn -q -N -f "$package_product_root/pom.xml" -Dmaven.repo.local="$maven_repo" install
    (cd "$lib_root" && mvn -q -Dmaven.repo.local="$maven_repo" install)
    (cd "$app_root" && mvn -q -Dmaven.repo.local="$maven_repo" test)
    ;;
  reactor)
    cd "$product_root"
    mvn -q test
    ;;
  *)
    echo "unknown verification_mode=$verification_mode" >&2
    exit 1
    ;;
esac
