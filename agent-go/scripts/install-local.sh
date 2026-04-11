#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/scripts/service-install-lib.sh"

PREFIX="${PREFIX:-"${HOME}/.local"}"
BIN_DIR="${BIN_DIR:-"${PREFIX}/bin"}"
INSTALL_SERVICE="${INSTALL_SERVICE:-0}"
ENABLE_SERVICE="${ENABLE_SERVICE:-0}"
SERVICE_MANAGER="${SERVICE_MANAGER:-auto}"
SERVICE_LABEL="${SERVICE_LABEL:-dev.a3.agent}"
POLL_INTERVAL="${POLL_INTERVAL:-2s}"
CONFIG_PATH="${CONFIG_PATH:-}"
WORKING_DIR="${WORKING_DIR:-}"

mkdir -p "${BIN_DIR}"

(
  cd "${ROOT_DIR}"
  go build -trimpath -o "${BIN_DIR}/a3-agent" ./cmd/a3-agent
)

echo "installed ${BIN_DIR}/a3-agent"
if ! command -v a3-agent >/dev/null 2>&1; then
  echo "note: ${BIN_DIR} is not currently on PATH"
fi

install_agent_service_if_requested
