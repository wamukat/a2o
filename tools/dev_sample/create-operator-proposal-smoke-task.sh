#!/usr/bin/env bash
set -eu

source "$(dirname "$0")/env.sh"

cd "$A2O_DEV_SAMPLE_ROOT"
KANBAN=(python3 tools/kanban/kanban_cli.py --backend kanbalone --base-url "$A2O_DEV_SAMPLE_KANBAN_URL")

description=$'A2O dev sample operator proposal smoke task.\n\n[operator-proposal-smoke]\n\nExpected behavior:\n- deterministic implementation edits utility-lib and web-app\n- worker result includes operator_proposals\n- completion comment includes compact Markdown proposal section\n- show-task exposes operator_proposals_count and proposal details'
task_json="$("${KANBAN[@]}" task-create \
  --project "$A2O_DEV_SAMPLE_PROJECT" \
  --status "To do" \
  --priority 2 \
  --title "[operator-proposal-smoke] Verify operator proposal visibility" \
  --description "$description")"

task_id="$(printf '%s' "$task_json" | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("id")')"
"${KANBAN[@]}" task-label-add --project "$A2O_DEV_SAMPLE_PROJECT" --task-id "$task_id" --title repo:app --reason "operator proposal smoke" >/dev/null
"${KANBAN[@]}" task-label-add --project "$A2O_DEV_SAMPLE_PROJECT" --task-id "$task_id" --title repo:lib --reason "operator proposal smoke" >/dev/null
"${KANBAN[@]}" task-label-add --project "$A2O_DEV_SAMPLE_PROJECT" --task-id "$task_id" --title trigger:auto-implement --reason "operator proposal smoke" >/dev/null

printf '%s\n' "$task_json"
