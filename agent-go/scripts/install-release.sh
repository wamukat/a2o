#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARCHIVE_PATH="${1:-}"
PREFIX="${PREFIX:-"${HOME}/.local"}"
BIN_DIR="${BIN_DIR:-"${PREFIX}/bin"}"
CHECKSUM_FILE="${CHECKSUM_FILE:-}"
VERIFY_CHECKSUMS="${VERIFY_CHECKSUMS:-0}"

if [[ -z "${ARCHIVE_PATH}" ]]; then
  echo "usage: install-release.sh /path/to/a2o-agent-<version>-<os>-<arch>.tar.gz" >&2
  exit 2
fi
if [[ ! -f "${ARCHIVE_PATH}" ]]; then
  echo "archive not found: ${ARCHIVE_PATH}" >&2
  exit 2
fi

sha256sum_or_shasum() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  else
    shasum -a 256 "${path}" | awk '{print $1}'
  fi
}

verify_archive_checksum() {
  local checksum_file="$1"
  local archive_path="$2"
  local archive_name
  local expected
  local actual
  archive_name="$(basename "${archive_path}")"
  if [[ ! -f "${checksum_file}" ]]; then
    echo "checksum file not found: ${checksum_file}" >&2
    exit 2
  fi
  expected="$(awk -v name="${archive_name}" '$2 == name { print $1; found=1 } END { if (!found) exit 1 }' "${checksum_file}")" || {
    echo "checksum entry not found for ${archive_name} in ${checksum_file}" >&2
    exit 2
  }
  actual="$(sha256sum_or_shasum "${archive_path}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "checksum mismatch for ${archive_name}: expected ${expected}, got ${actual}" >&2
    exit 1
  fi
  echo "verified checksum for ${archive_name}"
}

if [[ -n "${CHECKSUM_FILE}" ]]; then
  verify_archive_checksum "${CHECKSUM_FILE}" "${ARCHIVE_PATH}"
elif [[ "${VERIFY_CHECKSUMS}" == "1" ]]; then
  echo "CHECKSUM_FILE is required when VERIFY_CHECKSUMS=1" >&2
  exit 2
fi

mkdir -p "${BIN_DIR}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

case "${ARCHIVE_PATH}" in
  *.tar.gz | *.tgz)
    tar -C "${tmpdir}" -xzf "${ARCHIVE_PATH}"
    ;;
  *)
    echo "unsupported archive format: ${ARCHIVE_PATH}" >&2
    exit 2
    ;;
esac

binary_source=""
if [[ -f "${tmpdir}/a2o-agent" ]]; then
  binary_source="${tmpdir}/a2o-agent"
else
  echo "archive does not contain a2o-agent binary; migration_required=true replacement_archive=a2o-agent-<version>-<os>-<arch>.tar.gz" >&2
  exit 2
fi

install -m 0755 "${binary_source}" "${BIN_DIR}/a2o-agent"
rm -f "${BIN_DIR}/a3-agent"
echo "installed ${BIN_DIR}/a2o-agent"
if ! command -v a2o-agent >/dev/null 2>&1; then
  echo "note: ${BIN_DIR} is not currently on PATH"
fi
