#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT_DIR="${ROOT_DIR}/agent-go"
PORT="${PORT:-17396}"
BASE_URL="http://127.0.0.1:${PORT}"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""
RUNNER_PID=""
JOB_ID="command-run-1-verification-smoke"

dump_logs() {
  local status=$?
  if [[ "${status}" -ne 0 ]]; then
    for log in "${TMP_DIR}/agent-server.log" "${TMP_DIR}/runner.log" "${TMP_DIR}/agent.log"; do
      if [[ -f "${log}" ]]; then
        echo "---- ${log} ----" >&2
        tail -200 "${log}" >&2 || true
      fi
    done
  fi
  return "${status}"
}

cleanup() {
  local status=$?
  if [[ -n "${RUNNER_PID}" ]]; then
    kill "${RUNNER_PID}" >/dev/null 2>&1 || true
    wait "${RUNNER_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMP_DIR}"
  return "${status}"
}
trap 'dump_logs; cleanup' EXIT

SOURCE_ROOT="${TMP_DIR}/sources/member-portal-starters"
WORKSPACE_ROOT="${TMP_DIR}/agent-workspaces"
STORAGE_DIR="${TMP_DIR}/storage"
LOCAL_WORKSPACE="${TMP_DIR}/a3-local-workspace"

mkdir -p "${SOURCE_ROOT}"
git -C "${SOURCE_ROOT}" init -q
git -C "${SOURCE_ROOT}" config user.name "A3 Smoke"
git -C "${SOURCE_ROOT}" config user.email "a3-smoke@example.com"
printf 'materialized command source\n' > "${SOURCE_ROOT}/README.md"
git -C "${SOURCE_ROOT}" add README.md
git -C "${SOURCE_ROOT}" commit -q -m "initial source"
SOURCE_HEAD="$(git -C "${SOURCE_ROOT}" rev-parse HEAD)"
SOURCE_REF="refs/heads/a3/work/Portal-42"
git -C "${SOURCE_ROOT}" branch "a3/work/Portal-42" "${SOURCE_HEAD}"

ruby -I "${ROOT_DIR}/lib" "${ROOT_DIR}/bin/a3" agent-server \
  --storage-dir "${STORAGE_DIR}" \
  --host 127.0.0.1 \
  --port "${PORT}" > "${TMP_DIR}/agent-server.log" 2>&1 &
SERVER_PID="$!"

for _ in $(seq 1 50); do
  if curl -fsS "${BASE_URL}/v1/agent/jobs/next?agent=probe" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

cat > "${TMP_DIR}/runner.rb" <<'RUBY'
require "fileutils"
require "pathname"
require "a3"

base_url = ENV.fetch("BASE_URL")
source_ref = ENV.fetch("SOURCE_REF")
local_workspace = Pathname(ENV.fetch("LOCAL_WORKSPACE"))
FileUtils.mkdir_p(local_workspace)

source_descriptor = A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: "Portal#42", ref: source_ref)
workspace = A3::Domain::PreparedWorkspace.new(
  workspace_kind: :runtime_workspace,
  root_path: local_workspace,
  source_descriptor: source_descriptor,
  slot_paths: {}
)
task = A3::Domain::Task.new(
  ref: "Portal#42",
  kind: :single,
  edit_scope: [:repo_alpha],
  verification_scope: [:repo_alpha],
  status: :verifying
)
run = A3::Domain::Run.new(
  ref: "run-verification-1",
  task_ref: task.ref,
  phase: :verification,
  workspace_kind: :runtime_workspace,
  source_descriptor: source_descriptor,
  scope_snapshot: A3::Domain::ScopeSnapshot.new(
    edit_scope: [:repo_alpha],
    verification_scope: [:repo_alpha],
    ownership_scope: :task
  ),
  artifact_owner: A3::Domain::ArtifactOwner.new(
    owner_ref: task.ref,
    owner_scope: :task,
    snapshot_version: source_ref
  )
)
runner = A3::Infra::AgentCommandRunner.new(
  control_plane_client: A3::Infra::AgentControlPlaneClient.new(base_url: base_url),
  runtime_profile: "host-local",
  shared_workspace_mode: "agent-materialized",
  timeout_seconds: 60,
  poll_interval_seconds: 0.1,
  job_id_generator: -> { ENV.fetch("JOB_ID") },
  workspace_request_builder: A3::Infra::AgentWorkspaceRequestBuilder.new(
    source_aliases: {repo_alpha: "member-portal-starters"},
    cleanup_policy: :cleanup_after_job
  )
)
result = runner.run(
  [
    "test -f repo-alpha/README.md && " \
      "test -f .a3/workspace.json && " \
      "test -f repo-alpha/.a3/slot.json && " \
      "grep -q repo_source_root repo-alpha/.a3/slot.json"
  ],
  workspace: workspace,
  task: task,
  run: run
)
abort(result.summary) unless result.success?
puts result.summary
RUBY

BASE_URL="${BASE_URL}" SOURCE_REF="${SOURCE_REF}" LOCAL_WORKSPACE="${LOCAL_WORKSPACE}" JOB_ID="${JOB_ID}" \
  ruby -I "${ROOT_DIR}/lib" "${TMP_DIR}/runner.rb" > "${TMP_DIR}/runner.log" 2>&1 &
RUNNER_PID="$!"

for _ in $(seq 1 100); do
  if [[ -s "${STORAGE_DIR}/agent_jobs.json" ]]; then
    break
  fi
  sleep 0.1
done

(
  cd "${AGENT_DIR}"
  go build -trimpath -o "${TMP_DIR}/a3-agent" ./cmd/a3-agent
)

"${TMP_DIR}/a3-agent" \
  -agent host-local \
  -control-plane-url "${BASE_URL}" \
  -workspace-root "${WORKSPACE_ROOT}" \
  -source-alias "member-portal-starters=${SOURCE_ROOT}" > "${TMP_DIR}/agent.log" 2>&1

wait "${RUNNER_PID}"
RUNNER_PID=""

ruby -rjson -e "records = JSON.parse(File.read(ARGV.fetch(0))); abort 'job not completed' unless records.values.any? { |record| record.fetch('state') == 'completed' && record.fetch('request').fetch('job_id').include?('${JOB_ID}') }" "${STORAGE_DIR}/agent_jobs.json"
find "${STORAGE_DIR}/agent_artifacts/artifacts" -name '*combined-log.blob' | grep -q .
if git -C "${SOURCE_ROOT}" worktree list --porcelain | grep -q "${WORKSPACE_ROOT}"; then
  echo "materialized verification workspace was not cleaned up" >&2
  exit 1
fi

echo "a3 agent materialized command runner smoke ok"
