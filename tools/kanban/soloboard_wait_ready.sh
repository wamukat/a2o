#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <public-url>" >&2
  exit 1
fi

public_url="${1%/}"

for _ in $(seq 1 60); do
  if curl -fsS "${public_url}/api/health" >/dev/null 2>&1 || curl -fsS "${public_url}/api/boards" >/dev/null 2>&1; then
    echo "soloboard: ready (${public_url})"
    exit 0
  fi
  sleep 0.5
done

echo "soloboard: not ready (${public_url})" >&2
exit 1
