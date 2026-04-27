#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"

VERSION="${VERSION:-}"
if [[ -z "${VERSION}" ]]; then
  echo "VERSION is required, for example: VERSION=0.5.37 $0" >&2
  exit 2
fi

IMAGE="${IMAGE:-ghcr.io/wamukat/a2o-engine:${VERSION}-local}"
WORK_DIR="${WORK_DIR:-"${ENGINE_ROOT}/.work/local-rc-smoke-${VERSION}-$$"}"
KEEP_WORK="${KEEP_WORK:-0}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-"a2o-rc-smoke-${VERSION//./-}-$$"}"
EXPECT_LOCAL_NO_DIGEST="${EXPECT_LOCAL_NO_DIGEST:-1}"

cleanup() {
  if [[ -n "${HOST_A2O:-}" && -x "${HOST_A2O}" && -n "${WORKSPACE_DIR:-}" && -f "${WORKSPACE_DIR}/.work/a2o/runtime-instance.json" ]]; then
    (
      cd "${WORKSPACE_DIR}"
      A2O_RUNTIME_IMAGE="${IMAGE:-}" "${HOST_A2O}" runtime down >/dev/null 2>&1 || true
    )
  fi
  if [[ "${KEEP_WORK}" != "1" ]]; then
    rm -rf "${WORK_DIR}"
  fi
}
trap cleanup EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 2
  fi
}

find_free_port() {
  python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

run_a2o() {
  "${HOST_A2O}" "$@"
}

require_command docker
require_command git
require_command python3

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "runtime image not found locally: ${IMAGE}" >&2
  echo "build it first, for example:" >&2
  echo "  docker build -f docker/a3-runtime/Dockerfile -t ${IMAGE} ${ENGINE_ROOT}" >&2
  exit 2
fi

HOST_INSTALL_DIR="${WORK_DIR}/host-install"
WORKSPACE_DIR="${WORK_DIR}/workspace"
PACKAGE_DIR="${WORKSPACE_DIR}/project-package"
SOURCE_DIR="${WORKSPACE_DIR}/repo/app"
HOST_A2O="${HOST_INSTALL_DIR}/bin/a2o"
KANBALONE_PORT="${KANBALONE_PORT:-"$(find_free_port)"}"
AGENT_PORT="${AGENT_PORT:-"$(find_free_port)"}"

mkdir -p "${HOST_INSTALL_DIR}"

docker run --rm \
  -v "${HOST_INSTALL_DIR}:/install" \
  "${IMAGE}" \
  a2o host install \
    --output-dir /install/bin \
    --share-dir /install/share/a2o \
    --runtime-image "${IMAGE}"

run_a2o version | tee "${WORK_DIR}/host-version.out"
if ! grep -Fq "a2o version=${VERSION}" "${WORK_DIR}/host-version.out"; then
  echo "host launcher version mismatch; expected ${VERSION}" >&2
  exit 1
fi

mkdir -p "${PACKAGE_DIR}/commands" "${SOURCE_DIR}" "${WORKSPACE_DIR}"
git -C "${SOURCE_DIR}" init -q
git -C "${SOURCE_DIR}" config user.name "A2O RC Smoke"
git -C "${SOURCE_DIR}" config user.email "a2o-rc-smoke@example.com"
printf 'local rc smoke\n' > "${SOURCE_DIR}/README.md"
git -C "${SOURCE_DIR}" add README.md
git -C "${SOURCE_DIR}" commit -q -m "initial smoke source"

cat > "${PACKAGE_DIR}/project.yaml" <<EOF
schema_version: 1
package:
  name: local-rc-smoke
kanban:
  project: LocalRCSmoke
repos:
  app:
    path: ../repo/app
agent:
  required_bins:
    - sh
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - sh
          - -c
          - echo implementation smoke
    review:
      skill: skills/review/default.md
      executor:
        command:
          - sh
          - -c
          - echo review smoke
    verification:
      commands:
        - sh -c 'echo verification smoke'
    metrics:
      commands:
        - sh -c 'printf "{\"summary\":{\"tests_passed\":1,\"tests_failed\":0}}\n"'
    merge:
      policy: ff_only
      target_ref: refs/heads/main
EOF

run_a2o project validate --package "${PACKAGE_DIR}" | tee "${WORK_DIR}/project-validate.out"
grep -Fq "lint_status=ok" "${WORK_DIR}/project-validate.out"

run_a2o project bootstrap \
  --package "${PACKAGE_DIR}" \
  --workspace "${WORKSPACE_DIR}" \
  --compose-project "${COMPOSE_PROJECT}" \
  --kanbalone-port "${KANBALONE_PORT}" \
  --agent-port "${AGENT_PORT}"

(
  cd "${WORKSPACE_DIR}"
  export A2O_RUNTIME_IMAGE="${IMAGE}"
  run_a2o runtime up --build
  run_a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent --build
  run_a2o doctor | tee "${WORK_DIR}/doctor.out"
  run_a2o runtime image-digest | tee "${WORK_DIR}/image-digest.out"
  run_a2o runtime run-once --max-steps 0 --agent-attempts 1 --agent-poll-interval 1s | tee "${WORK_DIR}/runtime-run-once.out"
  run_a2o runtime down
)

grep -Fq "doctor_status=ok" "${WORK_DIR}/doctor.out"
grep -Fq "runtime_image_pinned_image_id=" "${WORK_DIR}/image-digest.out"
grep -Fq "runtime_image_running_status=current action=none" "${WORK_DIR}/image-digest.out"
grep -Fq "runtime_agent_export target=" "${WORK_DIR}/runtime-run-once.out"
grep -Fq "kanban_run_once_finished exit=0" "${WORK_DIR}/runtime-run-once.out"
if grep -Fq "removed A3 runtime package command" "${WORK_DIR}/runtime-run-once.out"; then
  echo "runtime run-once used removed A3 agent package command" >&2
  exit 1
fi

repo_digests="$(docker image inspect "${IMAGE}" --format '{{json .RepoDigests}}')"
if [[ "${EXPECT_LOCAL_NO_DIGEST}" == "1" && "${repo_digests}" == "[]" ]]; then
  grep -Fq "digest unavailable image_id=" "${WORK_DIR}/doctor.out"
fi

echo "local_rc_smoke=ok version=${VERSION} image=${IMAGE} compose_project=${COMPOSE_PROJECT} work_dir=${WORK_DIR}"
