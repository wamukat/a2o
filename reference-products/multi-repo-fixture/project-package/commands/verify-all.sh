#!/usr/bin/env sh
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"

if [ -d repo_alpha ] && [ -d repo_beta ]; then
  (cd repo_alpha && npm test)
  (cd repo_beta && npm test)
else
  "$script_dir/verify-repo-alpha.sh"
  "$script_dir/verify-repo-beta.sh"
fi
