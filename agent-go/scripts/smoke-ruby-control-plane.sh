#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT_DIR="${ROOT_DIR}/agent-go"
PORT="${PORT:-17393}"
BASE_URL="http://127.0.0.1:${PORT}"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${TMP_DIR}/workspace/target"
printf 'hello from go agent\n' > "${TMP_DIR}/workspace/input.txt"
printf '<testsuite />\n' > "${TMP_DIR}/workspace/target/surefire.xml"

ruby -I "${ROOT_DIR}/lib" "${ROOT_DIR}/bin/a3" agent-server \
  --storage-dir "${TMP_DIR}/storage" \
  --host 127.0.0.1 \
  --port "${PORT}" > "${TMP_DIR}/agent-server.log" 2>&1 &
SERVER_PID="$!"

for _ in $(seq 1 50); do
  if curl -fsS "${BASE_URL}/v1/agent/jobs/next?agent=probe" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

cat > "${TMP_DIR}/job.json" <<JSON
{
  "job_id": "job-1",
  "task_ref": "Portal#42",
  "phase": "verification",
  "runtime_profile": "host-local",
  "source_descriptor": {
    "workspace_kind": "runtime_workspace",
    "source_type": "detached_commit",
    "ref": "abc123",
    "task_ref": "Portal#42"
  },
  "working_dir": "${TMP_DIR}/workspace",
  "command": "ruby",
  "args": ["-e", "puts File.read('input.txt')"],
  "env": {},
  "timeout_seconds": 30,
  "artifact_rules": [
    {
      "role": "junit",
      "glob": "target/*.xml",
      "retention_class": "evidence",
      "media_type": "application/xml"
    }
  ]
}
JSON

curl -fsS \
  -H "content-type: application/json" \
  --data-binary "@${TMP_DIR}/job.json" \
  "${BASE_URL}/v1/agent/jobs" >/dev/null

(
  cd "${AGENT_DIR}"
  go build -trimpath -o "${TMP_DIR}/a3-agent" ./cmd/a3-agent
)

"${TMP_DIR}/a3-agent" -agent host-local -control-plane-url "${BASE_URL}" > "${TMP_DIR}/agent.log"

grep -q "agent completed job-1 status=succeeded" "${TMP_DIR}/agent.log"
test -f "${TMP_DIR}/storage/agent_artifacts/artifacts/job-1-combined-log.json"
test -f "${TMP_DIR}/storage/agent_artifacts/artifacts/job-1-junit-surefire.xml.json"

echo "go agent ruby control-plane smoke ok"
