#!/usr/bin/env sh
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"

if [ -d repo-alpha ] && [ -d repo-beta ]; then
  (cd repo-alpha && npm test)
  (cd repo-beta && npm test)
else
  "$script_dir/verify-repo-alpha.sh"
  "$script_dir/verify-repo-beta.sh"
fi
