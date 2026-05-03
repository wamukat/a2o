#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"

VERSION="${VERSION:-}"
if [[ -z "${VERSION}" ]]; then
  echo "VERSION is required, for example: VERSION=0.5.65 $0" >&2
  exit 2
fi

IMAGE="${IMAGE:-ghcr.io/wamukat/a2o-engine:${VERSION}-local}"
WORK_DIR="${WORK_DIR:-"${ENGINE_ROOT}/.work/real-task-rc-smoke-${VERSION}-$$"}"
KEEP_WORK="${KEEP_WORK:-0}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-"a2o-real-task-rc-smoke-${VERSION//./-}-$$"}"

cleanup() {
  if [[ -n "${HOST_A2O:-}" && -x "${HOST_A2O}" && -n "${WORKSPACE_DIR:-}" && -f "${WORKSPACE_DIR}/.work/a2o/runtime-instance.json" ]]; then
    (
      cd "${WORKSPACE_DIR}"
      A2O_RUNTIME_IMAGE="${IMAGE:-}" "${HOST_A2O}" runtime down >/dev/null 2>&1 || true
    )
  fi
  if [[ -n "${COMPOSE_PROJECT:-}" ]] && command -v docker >/dev/null 2>&1; then
    smoke_volumes="$(docker volume ls -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" 2>/dev/null || true)"
    if [[ -n "${smoke_volumes}" ]]; then
      # Docker volume names cannot contain whitespace.
      docker volume rm ${smoke_volumes} >/dev/null 2>&1 || true
    fi
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

api() {
  python3 - "$KANBALONE_URL" "$1" "$2" "${3:-}" <<'PY'
import json
import sys
import urllib.request

base = sys.argv[1].rstrip("/")
method = sys.argv[2]
path = sys.argv[3]
payload = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None

data = payload.encode("utf-8") if payload is not None else None
request = urllib.request.Request(
    base + path,
    data=data,
    method=method,
    headers={"content-type": "application/json"},
)
with urllib.request.urlopen(request, timeout=20) as response:
    body = response.read().decode("utf-8")
    if body:
        print(json.dumps(json.loads(body), ensure_ascii=False))
PY
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
WORKER_DIR="${PACKAGE_DIR}/commands"
HOST_A2O="${HOST_INSTALL_DIR}/bin/a2o"
KANBALONE_PORT="${KANBALONE_PORT:-"$(find_free_port)"}"
AGENT_PORT="${AGENT_PORT:-"$(find_free_port)"}"
KANBALONE_URL="http://127.0.0.1:${KANBALONE_PORT}"
RUN_ONCE_LOG="${WORK_DIR}/run-once.log"
RUN_ONCE_SERVER_LOG="${WORK_DIR}/run-once-agent-server.log"
RUN_ONCE_EXIT_FILE="${WORK_DIR}/run-once.exit"
RUN_ONCE_PID_FILE="${WORK_DIR}/run-once.pid"
RUN_ONCE_SERVER_PID_FILE="${WORK_DIR}/run-once-agent-server.pid"

mkdir -p "${HOST_INSTALL_DIR}" "${PACKAGE_DIR}/skills/implementation" "${PACKAGE_DIR}/skills/review" "${SOURCE_DIR}" "${WORKER_DIR}"

docker run --rm \
  -v "${HOST_INSTALL_DIR}:/install" \
  "${IMAGE}" \
  a2o host install \
    --output-dir /install/bin \
    --share-dir /install/share/a2o \
    --runtime-image "${IMAGE}"

"${HOST_A2O}" version | tee "${WORK_DIR}/host-version.out"
grep -Fq "a2o version=${VERSION}" "${WORK_DIR}/host-version.out"

git -C "${SOURCE_DIR}" init -q
git -C "${SOURCE_DIR}" config user.name "A2O Real Task RC Smoke"
git -C "${SOURCE_DIR}" config user.email "a2o-real-task-rc-smoke@example.com"
printf 'minimal real task smoke\n' > "${SOURCE_DIR}/README.md"
git -C "${SOURCE_DIR}" add README.md
git -C "${SOURCE_DIR}" commit -q -m "initial smoke source"

cat > "${PACKAGE_DIR}/project.yaml" <<'EOF'
schema_version: 1
package:
  name: real-task-rc-smoke
kanban:
  project: RealTaskRCSmoke
  selection:
    status: To do
repos:
  app:
    path: ../repo/app
    role: product
    label: repo:app
agent:
  required_bins:
    - ruby
runtime:
  max_steps: 20
  agent_attempts: 120
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - ruby
          - "{{root_dir}}/project-package/commands/worker.rb"
    review:
      skill: skills/review/default.md
      executor:
        command:
          - ruby
          - "{{root_dir}}/project-package/commands/worker.rb"
    verification:
      commands:
        - sh -c 'test -f "$A2O_WORKSPACE_ROOT/app/SMOKE.txt"'
    merge:
      policy: ff_only
      target_ref: refs/heads/main
EOF

cat > "${PACKAGE_DIR}/skills/implementation/base.md" <<'EOF'
# Implementation

Apply the requested minimal smoke change and return a valid A2O worker result.
EOF

cat > "${PACKAGE_DIR}/skills/review/default.md" <<'EOF'
# Review

Review the minimal smoke change and return a valid A2O worker result.
EOF

cat > "${WORKER_DIR}/worker.rb" <<'EOF'
# frozen_string_literal: true

require "json"
require "pathname"

request_path = Pathname(ENV.fetch("A2O_WORKER_REQUEST_PATH"))
result_path = Pathname(ENV.fetch("A2O_WORKER_RESULT_PATH"))
request = JSON.parse(request_path.read)

payload = {
  "task_ref" => request.fetch("task_ref"),
  "run_ref" => request.fetch("run_ref"),
  "phase" => request.fetch("phase"),
  "success" => true,
  "summary" => "minimal real-task RC smoke #{request.fetch("phase")} succeeded",
  "failing_command" => nil,
  "observed_state" => nil,
  "rework_required" => false
}

case request.fetch("phase")
when "implementation"
  app_root = Pathname(request.fetch("slot_paths").fetch("app"))
  app_root.join("SMOKE.txt").write("real task smoke\n")
  payload["changed_files"] = { "app" => ["SMOKE.txt"] }
  payload["review_disposition"] = {
    "kind" => "completed",
    "slot_scopes" => ["app"],
    "summary" => "minimal implementation self-review clean",
    "description" => "The smoke worker wrote the expected file.",
    "finding_key" => "minimal-real-task-rc-smoke-clean"
  }
when "review"
  payload["review_disposition"] = {
    "kind" => "completed",
    "slot_scopes" => ["app"],
    "summary" => "minimal review clean",
    "description" => "The smoke worker found no review findings.",
    "finding_key" => "minimal-real-task-rc-smoke-review-clean"
  }
else
  raise "unsupported phase #{request.fetch("phase")}"
end

result_path.dirname.mkpath
result_path.write(JSON.pretty_generate(payload))
EOF

"${HOST_A2O}" project validate --package "${PACKAGE_DIR}" | tee "${WORK_DIR}/project-validate.out"
grep -Fq "lint_status=ok" "${WORK_DIR}/project-validate.out"

"${HOST_A2O}" project bootstrap \
  --package "${PACKAGE_DIR}" \
  --workspace "${WORKSPACE_DIR}" \
  --compose-project "${COMPOSE_PROJECT}" \
  --kanbalone-port "${KANBALONE_PORT}" \
  --agent-port "${AGENT_PORT}"

(
  cd "${WORKSPACE_DIR}"
  export A2O_RUNTIME_IMAGE="${IMAGE}"
  "${HOST_A2O}" kanban up --build
  "${HOST_A2O}" runtime up --build
  "${HOST_A2O}" agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent --build
  "${HOST_A2O}" doctor | tee "${WORK_DIR}/doctor.out"
)
grep -Fq "doctor_status=ok" "${WORK_DIR}/doctor.out"

board_id="$(
  api GET /api/boards | python3 -c 'import json,sys; print(json.load(sys.stdin)["boards"][0]["id"])'
)"

board_json="$(api GET "/api/boards/${board_id}")"
lane_id="$(
  printf '%s\n' "${board_json}" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(next(l["id"] for l in data["lanes"] if l["name"]=="To do"))'
)"
repo_tag_id="$(
  printf '%s\n' "${board_json}" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(next(t["id"] for t in data["tags"] if t["name"]=="repo:app"))'
)"
trigger_tag_id="$(
  printf '%s\n' "${board_json}" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(next(t["id"] for t in data["tags"] if t["name"]=="trigger:auto-implement"))'
)"

task_json="$(
  api POST "/api/boards/${board_id}/tickets" "{
    \"laneId\": ${lane_id},
    \"title\": \"RC smoke: write marker file\",
    \"bodyMarkdown\": \"# Goal\\n\\nWrite a marker file through the A2O runtime worker.\\n\\n## Acceptance\\n\\n- implementation writes SMOKE.txt\\n- verification passes\\n- merge reaches Done\",
    \"priority\": 2,
    \"tagIds\": [${repo_tag_id}, ${trigger_tag_id}],
    \"blockerIds\": [],
    \"parentTicketId\": null,
    \"isResolved\": false,
    \"isArchived\": false
  }"
)"
task_ref="$(printf '%s\n' "${task_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ref"])')"

(
  cd "${WORKSPACE_DIR}"
  "${HOST_A2O}" runtime watch-summary | tee "${WORK_DIR}/watch-summary-before.out"
  grep -Fq "${task_ref#RealTaskRCSmoke}" "${WORK_DIR}/watch-summary-before.out"

  export A2O_RUNTIME_IMAGE="${IMAGE}"
  export A2O_RUNTIME_RUN_ONCE_LOG="${RUN_ONCE_LOG}"
  export A2O_RUNTIME_RUN_ONCE_SERVER_LOG="${RUN_ONCE_SERVER_LOG}"
  export A2O_RUNTIME_RUN_ONCE_EXIT_FILE="${RUN_ONCE_EXIT_FILE}"
  export A2O_RUNTIME_RUN_ONCE_PID_FILE="${RUN_ONCE_PID_FILE}"
  export A2O_RUNTIME_RUN_ONCE_SERVER_PID_FILE="${RUN_ONCE_SERVER_PID_FILE}"
  "${HOST_A2O}" runtime run-once --max-steps 20 --agent-attempts 180 --agent-poll-interval 1s | tee "${WORK_DIR}/runtime-run-once.out"
  "${HOST_A2O}" runtime watch-summary | tee "${WORK_DIR}/watch-summary-after.out"
  "${HOST_A2O}" runtime describe-task "${task_ref}" | tee "${WORK_DIR}/describe-task.out"
)

grep -Fq "steps=${task_ref}:implementation,${task_ref}:verification,${task_ref}:merge" "${WORK_DIR}/runtime-run-once.out"
grep -Fq "task ${task_ref} kind=single status=done" "${WORK_DIR}/describe-task.out"
grep -Fq "phase=merge" "${WORK_DIR}/describe-task.out"
grep -Fq "outcome=completed" "${WORK_DIR}/describe-task.out"
grep -Fq "review_disposition=kind=completed slot_scopes=app finding_key=minimal-real-task-rc-smoke-clean" "${WORK_DIR}/describe-task.out"
grep -Fq "o/o/o/o" "${WORK_DIR}/watch-summary-after.out"
git -C "${SOURCE_DIR}" log --oneline --max-count=1 | grep -Fq "A2O implementation update for ${task_ref}"

log_files=("${WORK_DIR}"/*.out)
for runtime_log in "${RUN_ONCE_LOG}" "${RUN_ONCE_SERVER_LOG}" "${RUN_ONCE_EXIT_FILE}"; do
  if [[ -f "${runtime_log}" ]]; then
    log_files+=("${runtime_log}")
  fi
done
if [[ -f "${WORKSPACE_DIR}/.work/a2o/runtime-host-agent/agent.log" ]]; then
  log_files+=("${WORKSPACE_DIR}/.work/a2o/runtime-host-agent/agent.log")
fi
if grep -E "A3_WORKSPACE_ROOT|A3_ROOT_DIR|A3_REPO_ROOT|A3_BUNDLE" "${log_files[@]}" >/dev/null 2>&1; then
  echo "removed A3 runtime surface appeared in real-task smoke logs" >&2
  exit 1
fi

echo "real_task_rc_smoke=ok version=${VERSION} image=${IMAGE} task=${task_ref} compose_project=${COMPOSE_PROJECT} work_dir=${WORK_DIR}"
