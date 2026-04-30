#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/env.sh"

cd "$A2O_DEV_SAMPLE_ROOT"
mkdir -p "$A2O_DEV_SAMPLE_STORAGE_DIR"

COMMON_OPTIONS=(
  --storage-backend sqlite
  --storage-dir "$A2O_DEV_SAMPLE_STORAGE_DIR"
  --repo-source "app=$A2O_DEV_SAMPLE_ROOT/reference-products/java-spring-multi-module/web-app"
  --repo-source "lib=$A2O_DEV_SAMPLE_ROOT/reference-products/java-spring-multi-module/utility-lib"
  --repo-source "docs=$A2O_DEV_SAMPLE_ROOT/reference-products/java-spring-multi-module/docs"
  --kanban-backend subprocess-cli
  --kanban-command python3
  --kanban-command-arg tools/kanban/kanban_cli.py
  --kanban-command-arg --backend
  --kanban-command-arg kanbalone
  --kanban-command-arg --base-url
  --kanban-command-arg "$A2O_DEV_SAMPLE_KANBAN_URL"
  --kanban-project "$A2O_DEV_SAMPLE_PROJECT"
  --kanban-status "To do"
  --kanban-trigger-label trigger:investigate
  --kanban-repo-label repo:app=app
  --kanban-repo-label repo:lib=lib
  --kanban-repo-label repo:docs=docs
)
RUNTIME_OPTIONS=(
  "${COMMON_OPTIONS[@]}"
  --preset-dir config/presets
)

plan_output="$(ruby -Ilib bin/a3 plan-next-decomposition-task "${COMMON_OPTIONS[@]}")"
printf '%s\n' "$plan_output"

task_ref="$(printf '%s\n' "$plan_output" | awk '/^next decomposition / { print $3; exit }')"
if [[ -z "$task_ref" ]]; then
  active_ref="$(printf '%s\n' "$plan_output" | awk '/^active decomposition / { print $3; exit }')"
  if [[ -n "$active_ref" ]]; then
    echo "active decomposition already exists: $active_ref"
    task_ref="$active_ref"
  else
    echo "no trigger:investigate task found in $A2O_DEV_SAMPLE_PROJECT / To do"
    echo "hint: the recognized label is trigger:investigate, not trigger:investigation"
    exit 0
  fi
fi

echo "running decomposition for $task_ref"

ruby -Ilib bin/a3 run-decomposition-investigation "$task_ref" "$A2O_DEV_SAMPLE_PACKAGE" "${RUNTIME_OPTIONS[@]}"
ruby -Ilib bin/a3 run-decomposition-proposal-author "$task_ref" "$A2O_DEV_SAMPLE_PACKAGE" "${RUNTIME_OPTIONS[@]}"
ruby -Ilib bin/a3 run-decomposition-proposal-review "$task_ref" "$A2O_DEV_SAMPLE_PACKAGE" "${RUNTIME_OPTIONS[@]}"
ruby -Ilib bin/a3 show-decomposition-status "$task_ref" \
  --storage-backend sqlite \
  --storage-dir "$A2O_DEV_SAMPLE_STORAGE_DIR"
