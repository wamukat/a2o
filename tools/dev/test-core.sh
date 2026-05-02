#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${A2O_TEST_LOG_DIR:-"${ROOT_DIR}/.work/test-core"}"
RUBY_CMD="${A2O_TEST_RUBY_CMD:-bundle exec rspec}"
GO_CMD="${A2O_TEST_GO_CMD:-cd agent-go && go test ./...}"
KANBAN_PY_CMD="${A2O_TEST_KANBAN_PY_CMD:-python3 -m unittest discover -s tools/kanban/tests}"
mkdir -p "${LOG_DIR}"

run_suite() {
  local label="$1"
  shift
  local log_path="${LOG_DIR}/${label}.log"
  local start
  local end
  local status

  start="$(date +%s)"
  echo "test_core_start suite=${label} log=${log_path}"
  (
    cd "${ROOT_DIR}" || exit 1
    "$@"
  ) >"${log_path}" 2>&1
  status=$?
  end="$(date +%s)"
  echo "test_core_done suite=${label} status=${status} seconds=$((end - start)) log=${log_path}"
  if [[ "${status}" -ne 0 ]]; then
    echo "test_core_failure_tail suite=${label}" >&2
    tail -80 "${log_path}" >&2
  fi
  return "${status}"
}

run_suite ruby "bash" "-c" "${RUBY_CMD}" &
ruby_pid=$!

run_suite go "bash" "-c" "${GO_CMD}" &
go_pid=$!

run_suite kanban_py "bash" "-c" "${KANBAN_PY_CMD}" &
kanban_pid=$!

overall=0
for pid in "${ruby_pid}" "${go_pid}" "${kanban_pid}"; do
  if ! wait "${pid}"; then
    overall=1
  fi
done

exit "${overall}"
