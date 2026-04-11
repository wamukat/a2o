#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PREFIX="${PREFIX:-"${HOME}/.local"}"
BIN_DIR="${BIN_DIR:-"${PREFIX}/bin"}"

mkdir -p "${BIN_DIR}"

(
  cd "${ROOT_DIR}"
  go build -trimpath -o "${BIN_DIR}/a3-agent" ./cmd/a3-agent
)

echo "installed ${BIN_DIR}/a3-agent"
if ! command -v a3-agent >/dev/null 2>&1; then
  echo "note: ${BIN_DIR} is not currently on PATH"
fi
