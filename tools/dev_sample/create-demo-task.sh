#!/usr/bin/env bash
set -eu

source "$(dirname "$0")/env.sh"

cd "$A2O_DEV_SAMPLE_ROOT"
KANBAN=(python3 tools/kanban/kanban_cli.py --backend kanbalone --base-url "$A2O_DEV_SAMPLE_KANBAN_URL")

description=$'A2O dev sample task for the Java Spring multi-module product.\n\nExpected behavior:\n- utility-lib owns greeting formatting\n- web-app exposes the HTTP endpoint\n- Maven reactor tests pass'
task_json="$("${KANBAN[@]}" task-create \
  --project "$A2O_DEV_SAMPLE_PROJECT" \
  --status "To do" \
  --priority 2 \
  --title "[sample] Add salutation endpoint" \
  --description "$description")"

task_id="$(printf '%s' "$task_json" | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("id")')"
"${KANBAN[@]}" task-label-add --project "$A2O_DEV_SAMPLE_PROJECT" --task-id "$task_id" --title repo:app --reason "dev sample" >/dev/null
"${KANBAN[@]}" task-label-add --project "$A2O_DEV_SAMPLE_PROJECT" --task-id "$task_id" --title repo:lib --reason "dev sample" >/dev/null
"${KANBAN[@]}" task-label-add --project "$A2O_DEV_SAMPLE_PROJECT" --task-id "$task_id" --title trigger:auto-implement --reason "dev sample" >/dev/null

printf '%s\n' "$task_json"
