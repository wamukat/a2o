#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT_DIR="${ROOT_DIR}/agent-go"
PORT="${PORT:-17395}"
BASE_URL="http://127.0.0.1:${PORT}"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""
GATEWAY_PID=""
JOB_ID="worker-run-1-implementation-gateway-smoke"

dump_logs() {
  local status=$?
  if [[ "${status}" -ne 0 ]]; then
    for log in "${TMP_DIR}/agent-server.log" "${TMP_DIR}/gateway.log" "${TMP_DIR}/agent.log"; do
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
  if [[ -n "${GATEWAY_PID}" ]]; then
    kill "${GATEWAY_PID}" >/dev/null 2>&1 || true
    wait "${GATEWAY_PID}" >/dev/null 2>&1 || true
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
LOCAL_WORKSPACE="${TMP_DIR}/gateway-local-workspace"

mkdir -p "${SOURCE_ROOT}"
git -C "${SOURCE_ROOT}" init -q
git -C "${SOURCE_ROOT}" config user.name "A3 Smoke"
git -C "${SOURCE_ROOT}" config user.email "a3-smoke@example.com"
printf 'materialized gateway source\n' > "${SOURCE_ROOT}/README.md"
git -C "${SOURCE_ROOT}" add README.md
git -C "${SOURCE_ROOT}" commit -q -m "initial source"
SOURCE_HEAD="$(git -C "${SOURCE_ROOT}" rev-parse HEAD)"

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

cat > "${TMP_DIR}/gateway.rb" <<'RUBY'
require "json"
require "pathname"
require "fileutils"
require "a3"

base_url = ENV.fetch("BASE_URL")
source_head = ENV.fetch("SOURCE_HEAD")
local_workspace = Pathname(ENV.fetch("LOCAL_WORKSPACE"))
FileUtils.mkdir_p(local_workspace)

source_descriptor = A3::Domain::SourceDescriptor.implementation(task_ref: "Portal#42", ref: source_head)
workspace = A3::Domain::PreparedWorkspace.new(
  workspace_kind: :ticket_workspace,
  root_path: local_workspace,
  source_descriptor: source_descriptor,
  slot_paths: {}
)
task = A3::Domain::Task.new(
  ref: "Portal#42",
  kind: :child,
  edit_scope: [:repo_beta],
  verification_scope: [:repo_beta]
)
run = A3::Domain::Run.new(
  ref: "run-1",
  task_ref: task.ref,
  phase: :implementation,
  workspace_kind: :ticket_workspace,
  source_descriptor: source_descriptor,
  scope_snapshot: A3::Domain::ScopeSnapshot.new(
    edit_scope: [:repo_beta],
    verification_scope: [:repo_beta],
    ownership_scope: :child
  ),
  artifact_owner: A3::Domain::ArtifactOwner.new(
    owner_ref: task.ref,
    owner_scope: :child,
    snapshot_version: source_head
  )
)
task_packet = A3::Domain::WorkerTaskPacket.new(
  ref: task.ref,
  external_task_id: 42,
  kind: task.kind,
  edit_scope: task.edit_scope,
  verification_scope: task.verification_scope,
  parent_ref: task.parent_ref,
  child_refs: task.child_refs,
  title: "Gateway materialized smoke",
  description: "Exercise AgentWorkerGateway with agent-owned workspace.",
  status: "In progress",
  labels: []
)
phase_runtime = A3::Domain::PhaseRuntimeConfig.new(
  task_kind: :child,
  repo_scope: :ui_app,
  phase: :implementation,
  implementation_skill: "gateway smoke implementation",
  review_skill: "gateway smoke review",
  verification_commands: [],
  remediation_commands: [],
  workspace_hook: "bootstrap",
  merge_target: :merge_to_parent,
  merge_policy: :squash
)

worker_command = <<~SH
  set -eu
  test -f repo-beta/README.md
  printf "changed by gateway worker\\n" > repo-beta/changed.txt
  mkdir -p "$(dirname "$A3_WORKER_RESULT_PATH")"
  cat > "$A3_WORKER_RESULT_PATH" <<JSON
  {"success":true,"summary":"materialized gateway worker completed","task_ref":"Portal#42","run_ref":"run-1","phase":"implementation","rework_required":false,"changed_files":{"repo_beta":["worker-claimed.txt"]},"review_disposition":{"kind":"completed","repo_scope":"repo_beta","summary":"done","description":"done","finding_key":"none"}}
  JSON
  echo "materialized gateway worker ok"
SH

gateway = A3::Infra::AgentWorkerGateway.new(
  control_plane_client: A3::Infra::AgentControlPlaneClient.new(base_url: base_url),
  worker_command: "sh",
  worker_command_args: ["-lc", worker_command],
  runtime_profile: "host-local",
  shared_workspace_mode: "agent-materialized",
  timeout_seconds: 30,
  poll_interval_seconds: 0.05,
  job_id_generator: -> { "gateway-smoke" },
  workspace_request_builder: A3::Infra::AgentWorkspaceRequestBuilder.new(
    source_aliases: { repo_beta: "member-portal-starters" },
    cleanup_policy: :cleanup_after_job
  )
)

execution = gateway.run(
  skill: phase_runtime.implementation_skill,
  workspace: workspace,
  task: task,
  run: run,
  phase_runtime: phase_runtime,
  task_packet: task_packet
)
raise "gateway failed: #{execution.inspect}" unless execution.success
raise "canonical changed_files mismatch: #{execution.response_bundle.inspect}" unless execution.response_bundle.fetch("changed_files") == { "repo_beta" => ["changed.txt"] }
raise "missing worker mismatch diagnostics" unless execution.diagnostics.fetch("worker_changed_files") == { "repo_beta" => ["worker-claimed.txt"] }
raise "missing canonical mismatch diagnostics" unless execution.diagnostics.fetch("canonical_changed_files") == { "repo_beta" => ["changed.txt"] }
puts "gateway materialized execution ok"
RUBY

BASE_URL="${BASE_URL}" SOURCE_HEAD="${SOURCE_HEAD}" LOCAL_WORKSPACE="${LOCAL_WORKSPACE}" \
  ruby -I "${ROOT_DIR}/lib" "${TMP_DIR}/gateway.rb" > "${TMP_DIR}/gateway.log" 2>&1 &
GATEWAY_PID="$!"

for _ in $(seq 1 100); do
  if curl -fsS "${BASE_URL}/v1/agent/jobs/${JOB_ID}" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

(
  cd "${AGENT_DIR}"
  go build -trimpath -o "${TMP_DIR}/a3-agent" ./cmd/a3-agent
)

AGENT_PROFILE="${TMP_DIR}/agent-profile.json"
AGENT_PROFILE="${AGENT_PROFILE}" BASE_URL="${BASE_URL}" WORKSPACE_ROOT="${WORKSPACE_ROOT}" SOURCE_ROOT="${SOURCE_ROOT}" ruby -rjson -e '
  File.write(
    ENV.fetch("AGENT_PROFILE"),
    JSON.pretty_generate(
      "agent" => "host-local",
      "control_plane_url" => ENV.fetch("BASE_URL"),
      "workspace_root" => ENV.fetch("WORKSPACE_ROOT"),
      "source_aliases" => {
        "member-portal-starters" => ENV.fetch("SOURCE_ROOT")
      }
    )
  )
'

"${TMP_DIR}/a3-agent" \
  doctor \
  -config "${AGENT_PROFILE}" >> "${TMP_DIR}/agent.log"

"${TMP_DIR}/a3-agent" \
  -config "${AGENT_PROFILE}" >> "${TMP_DIR}/agent.log"

wait "${GATEWAY_PID}"
GATEWAY_PID=""

grep -q "gateway materialized execution ok" "${TMP_DIR}/gateway.log"
grep -q "agent completed ${JOB_ID} status=succeeded" "${TMP_DIR}/agent.log"

JOB_RESULT_PATH="${TMP_DIR}/job-result.json"
curl -fsS "${BASE_URL}/v1/agent/jobs/${JOB_ID}" > "${JOB_RESULT_PATH}"

JOB_RESULT_PATH="${JOB_RESULT_PATH}" SOURCE_HEAD="${SOURCE_HEAD}" SOURCE_ROOT="${SOURCE_ROOT}" WORKSPACE_ROOT="${WORKSPACE_ROOT}" ruby -rjson -e '
  job = JSON.parse(File.read(ENV.fetch("JOB_RESULT_PATH"))).fetch("job")
  result = job.fetch("result")
  raise "job was not completed" unless job.fetch("state") == "completed"
  raise "job did not succeed" unless result.fetch("status") == "succeeded"
  worker_result = result.fetch("worker_protocol_result")
  raise "missing worker protocol result" unless worker_result.fetch("summary") == "materialized gateway worker completed"
  uploads = result.fetch("artifact_uploads")
  raise "missing worker-result artifact" unless uploads.any? { |upload| upload.fetch("role") == "worker-result" }
  slot = result.fetch("workspace_descriptor").fetch("slot_descriptors").fetch("repo_beta")
  raise "source alias mismatch" unless slot.fetch("source_alias") == "member-portal-starters"
  raise "checkout mismatch" unless slot.fetch("checkout") == "worktree_detached"
  raise "requested ref mismatch" unless slot.fetch("requested_ref") == ENV.fetch("SOURCE_HEAD")
  raise "access mismatch" unless slot.fetch("access") == "read_write"
  raise "dirty_before should be false" unless slot.fetch("dirty_before") == false
  raise "dirty_after should be true" unless slot.fetch("dirty_after") == true
  raise "changed_files evidence mismatch" unless slot.fetch("changed_files") == ["changed.txt"]
  runtime_path = slot.fetch("runtime_path")
  raise "runtime path outside workspace root" unless runtime_path.start_with?(ENV.fetch("WORKSPACE_ROOT"))
  raise "materialized workspace was not cleaned" if File.exist?(File.join(ENV.fetch("WORKSPACE_ROOT"), "Portal-42-implementation-run-1"))
  worktree_list = `git -C "#{ENV.fetch("SOURCE_ROOT")}" worktree list --porcelain`
  raise "worktree registration leaked" if worktree_list.include?(runtime_path)
'

test -f "${STORAGE_DIR}/agent_artifacts/artifacts/${JOB_ID}-worker-result.json"

echo "go agent materialized gateway smoke ok"
