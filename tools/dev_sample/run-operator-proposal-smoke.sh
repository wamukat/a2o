#!/usr/bin/env bash
set -eu

source "$(dirname "$0")/env.sh"

cd "$A2O_DEV_SAMPLE_ROOT"

cleanup() {
  tools/dev_sample/stop-agent.sh >/dev/null 2>&1 || true
  tools/dev_sample/stop-kanbalone.sh >/dev/null 2>&1 || true
}
trap cleanup EXIT

tools/dev_sample/reset.sh >/dev/null
tools/dev_sample/start-kanbalone.sh >/dev/null
tools/dev_sample/bootstrap-kanban.sh >/dev/null
tools/dev_sample/start-agent.sh >/dev/null

task_json="$(tools/dev_sample/create-operator-proposal-smoke-task.sh)"
task_id="$(printf '%s' "$task_json" | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("id")')"
task_ref="$(printf '%s' "$task_json" | A2O_DEV_SAMPLE_PROJECT="$A2O_DEV_SAMPLE_PROJECT" ruby -rjson -e 'task = JSON.parse(STDIN.read); puts(task["ref"] || "#{ENV.fetch("A2O_DEV_SAMPLE_PROJECT")}##{task.fetch("id")}")')"

A2O_DEV_SAMPLE_MAX_STEPS=1 tools/dev_sample/run-once.sh >/dev/null

show_output="$(ruby -Ilib bin/a3 show-task \
  --storage-backend sqlite \
  --storage-dir "$A2O_DEV_SAMPLE_STORAGE_DIR" \
  "$task_ref")"

printf '%s\n' "$show_output" | grep -q "operator_proposals_count=1"
printf '%s\n' "$show_output" | grep -q "operator_proposal_title=Review deterministic worker smoke policy"
printf '%s\n' "$show_output" | grep -q "operator_proposal_suggested_action=Keep this smoke marker available for release validation of proposal visibility."

comments_json="$(python3 tools/kanban/kanban_cli.py \
  --backend kanbalone \
  --base-url "$A2O_DEV_SAMPLE_KANBAN_URL" \
  task-comment-list \
  --project "$A2O_DEV_SAMPLE_PROJECT" \
  --task-id "$task_id")"
printf '%s\n' "$comments_json" | grep -q "Operator proposals"
printf '%s\n' "$comments_json" | grep -q "Review deterministic worker smoke policy"

echo "operator_proposal_smoke=passed task_ref=$task_ref task_id=$task_id"
