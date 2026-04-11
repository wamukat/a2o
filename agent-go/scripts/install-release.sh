#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/service-install-lib.sh"

ARCHIVE_PATH="${1:-}"
PREFIX="${PREFIX:-"${HOME}/.local"}"
BIN_DIR="${BIN_DIR:-"${PREFIX}/bin"}"
INSTALL_SERVICE="${INSTALL_SERVICE:-0}"
ENABLE_SERVICE="${ENABLE_SERVICE:-0}"
SERVICE_MANAGER="${SERVICE_MANAGER:-auto}"
SERVICE_LABEL="${SERVICE_LABEL:-dev.a3.agent}"
POLL_INTERVAL="${POLL_INTERVAL:-2s}"
CONFIG_PATH="${CONFIG_PATH:-}"
WORKING_DIR="${WORKING_DIR:-}"

if [[ -z "${ARCHIVE_PATH}" ]]; then
  echo "usage: install-release.sh /path/to/a3-agent-<version>-<os>-<arch>.tar.gz|.zip" >&2
  exit 2
fi
if [[ ! -f "${ARCHIVE_PATH}" ]]; then
  echo "archive not found: ${ARCHIVE_PATH}" >&2
  exit 2
fi

mkdir -p "${BIN_DIR}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

case "${ARCHIVE_PATH}" in
  *.tar.gz | *.tgz)
    tar -C "${tmpdir}" -xzf "${ARCHIVE_PATH}"
    ;;
  *.zip)
    if ! command -v unzip >/dev/null 2>&1; then
      echo "unzip is required to install zip archives" >&2
      exit 2
    fi
    unzip -q "${ARCHIVE_PATH}" -d "${tmpdir}"
    ;;
  *)
    echo "unsupported archive format: ${ARCHIVE_PATH}" >&2
    exit 2
    ;;
esac

binary_source=""
if [[ -f "${tmpdir}/a3-agent" ]]; then
  binary_source="${tmpdir}/a3-agent"
elif [[ -f "${tmpdir}/a3-agent.exe" ]]; then
  binary_source="${tmpdir}/a3-agent.exe"
else
  echo "archive does not contain a3-agent binary" >&2
  exit 2
fi

install -m 0755 "${binary_source}" "${BIN_DIR}/a3-agent"
echo "installed ${BIN_DIR}/a3-agent"
if ! command -v a3-agent >/dev/null 2>&1; then
  echo "note: ${BIN_DIR} is not currently on PATH"
fi

install_agent_service_if_requested
