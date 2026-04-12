#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT_DIR="${ROOT_DIR}/agent-go"
PORT="${PORT:-17394}"
BASE_URL="http://127.0.0.1:${PORT}"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""

dump_logs() {
  local status=$?
  if [[ "${status}" -ne 0 ]]; then
    for log in "${TMP_DIR}/agent-server.log" "${TMP_DIR}/agent.log"; do
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

mkdir -p "${SOURCE_ROOT}"
git -C "${SOURCE_ROOT}" init -q
git -C "${SOURCE_ROOT}" config user.name "A3 Smoke"
git -C "${SOURCE_ROOT}" config user.email "a3-smoke@example.com"
printf 'materialized source\n' > "${SOURCE_ROOT}/README.md"
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

JOB_PATH="${TMP_DIR}/job.json"
JOB_PATH="${JOB_PATH}" SOURCE_REF="${SOURCE_REF}" ruby -rjson -e '
  job_path = ENV.fetch("JOB_PATH")
  source_ref = ENV.fetch("SOURCE_REF")
  command = <<~SH
    set -eu
    test -f repo-alpha/README.md
    printf "changed by worker\n" > repo-alpha/changed.txt
    mkdir -p "$(dirname "$A3_WORKER_RESULT_PATH")"
    cat > "$A3_WORKER_RESULT_PATH" <<JSON
    {"success":true,"summary":"materialized worker completed","task_ref":"Portal#42","run_ref":"run-42","phase":"implementation","rework_required":false,"changed_files":{}}
    JSON
    echo "materialized worker protocol ok"
  SH
  File.write(
    job_path,
    JSON.pretty_generate(
      "job_id" => "job-materialized-1",
      "task_ref" => "Portal#42",
      "phase" => "implementation",
      "runtime_profile" => "host-local",
      "source_descriptor" => {
        "workspace_kind" => "ticket_workspace",
        "source_type" => "branch_head",
        "ref" => source_ref,
        "task_ref" => "Portal#42"
      },
      "workspace_request" => {
        "mode" => "agent_materialized",
        "workspace_kind" => "ticket_workspace",
        "workspace_id" => "Portal-42-ticket",
        "freshness_policy" => "reuse_if_clean_and_ref_matches",
        "cleanup_policy" => "cleanup_after_job",
        "slots" => {
          "repo_alpha" => {
            "source" => {
              "kind" => "local_git",
              "alias" => "member-portal-starters"
            },
            "ref" => source_ref,
            "checkout" => "worktree_branch",
            "access" => "read_write",
            "sync_class" => "eager",
            "ownership" => "edit_target",
            "required" => true
          }
        }
      },
      "worker_protocol_request" => {
        "task_ref" => "Portal#42",
        "run_ref" => "run-42",
        "phase" => "implementation"
      },
      "working_dir" => ".",
      "command" => "sh",
      "args" => ["-lc", command],
      "env" => {},
      "timeout_seconds" => 30,
      "artifact_rules" => []
    )
  )
'

curl -fsS \
  -H "content-type: application/json" \
  --data-binary "@${JOB_PATH}" \
  "${BASE_URL}/v1/agent/jobs" >/dev/null

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

grep -q "agent completed job-materialized-1 status=succeeded" "${TMP_DIR}/agent.log"

JOB_RESULT_PATH="${TMP_DIR}/job-result.json"
curl -fsS "${BASE_URL}/v1/agent/jobs/job-materialized-1" > "${JOB_RESULT_PATH}"

JOB_RESULT_PATH="${JOB_RESULT_PATH}" SOURCE_REF="${SOURCE_REF}" SOURCE_ROOT="${SOURCE_ROOT}" WORKSPACE_ROOT="${WORKSPACE_ROOT}" ruby -rjson -e '
  job = JSON.parse(File.read(ENV.fetch("JOB_RESULT_PATH"))).fetch("job")
  result = job.fetch("result")
  raise "job was not completed" unless job.fetch("state") == "completed"
  raise "job did not succeed" unless result.fetch("status") == "succeeded"
  worker_result = result.fetch("worker_protocol_result")
  raise "missing worker protocol result" unless worker_result.fetch("summary") == "materialized worker completed"
  uploads = result.fetch("artifact_uploads")
  raise "missing worker-result artifact" unless uploads.any? { |upload| upload.fetch("role") == "worker-result" }
  slot = result.fetch("workspace_descriptor").fetch("slot_descriptors").fetch("repo_alpha")
  raise "source alias mismatch" unless slot.fetch("source_alias") == "member-portal-starters"
  raise "checkout mismatch" unless slot.fetch("checkout") == "worktree_branch"
  raise "requested ref mismatch" unless slot.fetch("requested_ref") == ENV.fetch("SOURCE_REF")
  raise "sync class mismatch" unless slot.fetch("sync_class") == "eager"
  raise "ownership mismatch" unless slot.fetch("ownership") == "edit_target"
  runtime_path = slot.fetch("runtime_path")
  raise "runtime path outside workspace root" unless runtime_path.start_with?(ENV.fetch("WORKSPACE_ROOT"))
  changed_files = slot.fetch("changed_files")
  raise "changed_files evidence mismatch: #{changed_files.inspect}" unless changed_files == ["changed.txt"]
  raise "dirty_after should be true" unless slot.fetch("dirty_after") == true
  raise "materialized workspace was not cleaned" if File.exist?(File.join(ENV.fetch("WORKSPACE_ROOT"), "Portal-42-ticket"))
  worktree_list = `git -C "#{ENV.fetch("SOURCE_ROOT")}" worktree list --porcelain`
  raise "worktree registration leaked" if worktree_list.include?(runtime_path)
'

test -f "${STORAGE_DIR}/agent_artifacts/artifacts/job-materialized-1-worker-result.json"

echo "go agent materialized worker protocol smoke ok"
