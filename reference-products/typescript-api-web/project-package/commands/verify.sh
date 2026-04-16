#!/usr/bin/env sh
set -eu

product_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$product_root"

if [ ! -d node_modules ]; then
  npm install --ignore-scripts
fi

npm run typecheck
npm test
