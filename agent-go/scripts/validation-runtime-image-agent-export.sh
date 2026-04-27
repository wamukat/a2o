#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${ENGINE_ROOT}/.." && pwd)"

COMPOSE_PROJECT="${COMPOSE_PROJECT:-a2o-runtime}"
COMPOSE_FILE="${COMPOSE_FILE:-${ENGINE_ROOT}/docker/compose/a2o-kanbalone.yml}"
RUNTIME_SERVICE="${RUNTIME_SERVICE:-a2o-runtime}"

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
work_dir="$(mktemp -d)"
cleanup() {
  if [[ "${KEEP_VALIDATION_WORK:-0}" != "1" ]]; then
    rm -rf "${work_dir}"
  fi
}
trap cleanup EXIT

exported_agent="${work_dir}/a2o-agent"
source_root="${work_dir}/source/catalog-service"
workspace_root="${work_dir}/workspaces"

A2O_BUNDLE_KANBALONE_PORT="${A2O_BUNDLE_KANBALONE_PORT:-3470}" \
docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" build "${RUNTIME_SERVICE}"

A2O_BUNDLE_KANBALONE_PORT="${A2O_BUNDLE_KANBALONE_PORT:-3470}" \
docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" up -d --no-deps --force-recreate "${RUNTIME_SERVICE}"

runtime_container="$(docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" ps -q "${RUNTIME_SERVICE}")"
docker exec "${runtime_container}" a2o agent package verify --target "${target}"
docker exec "${runtime_container}" a2o agent package export --target "${target}" --output /tmp/a2o-agent-validation
docker cp "${runtime_container}:/tmp/a2o-agent-validation" "${exported_agent}"
chmod +x "${exported_agent}"

mkdir -p "${source_root}"
git -C "${source_root}" init -q
git -C "${source_root}" config user.name "A2O Runtime Image Validation"
git -C "${source_root}" config user.email "a2o-runtime-image-validation@example.com"
printf 'runtime image validation\n' > "${source_root}/README.md"
git -C "${source_root}" add README.md
git -C "${source_root}" commit -q -m "initial runtime image validation source"

"${exported_agent}" doctor \
  --control-plane-url http://127.0.0.1:7393 \
  --workspace-root "${workspace_root}" \
  --source-path "catalog-service=${source_root}" \
  --required-bin git

echo "runtime_image_agent_export_validation=ok target=${target} workspace=${WORKSPACE_ROOT}"
