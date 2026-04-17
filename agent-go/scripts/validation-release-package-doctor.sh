#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"

detect_host_target() {
  local os
  local arch
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    *) echo "unsupported host OS: $(uname -s)" >&2; exit 2 ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch="amd64" ;;
    arm64 | aarch64) arch="arm64" ;;
    *) echo "unsupported host architecture: $(uname -m)" >&2; exit 2 ;;
  esac
  printf '%s-%s\n' "${os}" "${arch}"
}

target="${TARGET:-"$(detect_host_target)"}"
goos="${target%-*}"
goarch="${target#*-}"
if [[ -z "${goos}" || -z "${goarch}" || "${goos}" == "${goarch}" ]]; then
  echo "TARGET must be <goos>-<goarch>: ${target}" >&2
  exit 2
fi

work_dir="$(mktemp -d)"
cleanup() {
  if [[ "${KEEP_VALIDATION_WORK:-0}" != "1" ]]; then
    rm -rf "${work_dir}"
  fi
}
trap cleanup EXIT

dist_dir="${DIST_DIR:-"${work_dir}/dist"}"
exported_agent="${work_dir}/bin/a3-agent"
source_root="${work_dir}/source/catalog-service"
workspace_root="${work_dir}/workspaces"

TARGETS="${goos}/${goarch}" VERSION="${VERSION:-validation}" DIST_DIR="${dist_dir}" "${ROOT_DIR}/scripts/build-release.sh"

ruby -I "${ENGINE_ROOT}/lib" "${ENGINE_ROOT}/bin/a3" agent package verify \
  --package-dir "${dist_dir}" \
  --target "${target}"

ruby -I "${ENGINE_ROOT}/lib" "${ENGINE_ROOT}/bin/a3" agent package export \
  --package-dir "${dist_dir}" \
  --target "${target}" \
  --output "${exported_agent}"

mkdir -p "${source_root}"
git -C "${source_root}" init -q
git -C "${source_root}" config user.name "A3 Release Validation"
git -C "${source_root}" config user.email "a3-release-validation@example.com"
printf 'release validation\n' > "${source_root}/README.md"
git -C "${source_root}" add README.md
git -C "${source_root}" commit -q -m "initial release validation source"

"${exported_agent}" doctor \
  --control-plane-url http://127.0.0.1:7393 \
  --workspace-root "${workspace_root}" \
  --source-path "catalog-service=${source_root}" \
  --required-bin git

echo "release_package_validation=ok target=${target} package_dir=${dist_dir}"
