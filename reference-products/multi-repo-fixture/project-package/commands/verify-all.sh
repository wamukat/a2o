#!/usr/bin/env sh
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"

"$script_dir/verify-repo-alpha.sh"
"$script_dir/verify-repo-beta.sh"
