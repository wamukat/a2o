#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <public-url>" >&2
  exit 1
fi

public_url="$1"

echo "public_url=${public_url%/}/"
echo "api_url=${public_url%/}/api/boards"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker: missing"
  exit 1
fi

echo "docker: ok"
docker ps --filter "name=soloboard" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

if curl -fsS "${public_url%/}/" >/dev/null 2>&1; then
  echo "http: ok (${public_url%/}/)"
else
  echo "http: not ready (${public_url%/}/)"
fi

if curl -fsS "${public_url%/}/api/boards" >/dev/null 2>&1; then
  echo "api: ok (${public_url%/}/api/boards)"
else
  echo "api: not ready (${public_url%/}/api/boards)"
fi
