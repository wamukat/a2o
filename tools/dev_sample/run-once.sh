#!/usr/bin/env sh
set -eu

. "$(dirname "$0")/env.sh"

cd "$A2O_DEV_SAMPLE_ROOT"
mkdir -p "$A2O_DEV_SAMPLE_STORAGE_DIR"

"$A2O_DEV_SAMPLE_ROOT/tools/dev_sample/prepare-sources.sh" >/dev/null
app_source="$A2O_DEV_SAMPLE_ROOT/.work/a2o-dev-sample/sources/web-app"
lib_source="$A2O_DEV_SAMPLE_ROOT/.work/a2o-dev-sample/sources/utility-lib"

ruby -Ilib bin/a3 execute-until-idle \
  --storage-backend sqlite \
  --storage-dir "$A2O_DEV_SAMPLE_STORAGE_DIR" \
  --repo-source "app=$app_source" \
  --repo-source "lib=$lib_source" \
  --preset-dir config/presets \
  --kanban-backend subprocess-cli \
  --kanban-command python3 \
  --kanban-command-arg tools/kanban/kanban_cli.py \
  --kanban-command-arg --backend \
  --kanban-command-arg kanbalone \
  --kanban-command-arg --base-url \
  --kanban-command-arg "$A2O_DEV_SAMPLE_KANBAN_URL" \
  --kanban-project "$A2O_DEV_SAMPLE_PROJECT" \
  --kanban-status "To do" \
  --kanban-trigger-label trigger:auto-implement \
  --kanban-repo-label repo:app=app \
  --kanban-repo-label repo:lib=lib \
  --worker-gateway agent-http \
  --verification-command-runner agent-http \
  --merge-runner agent-http \
  --agent-control-plane-url "$A2O_DEV_SAMPLE_AGENT_URL" \
  --agent-runtime-profile dev-sample \
  --agent-shared-workspace-mode agent-materialized \
  --agent-source-alias app=app \
  --agent-source-alias lib=lib \
  --agent-source-path "app=$app_source" \
  --agent-source-path "lib=$lib_source" \
  --agent-support-ref refs/heads/a2o/dev-sample-live \
  --agent-workspace-root "$A2O_DEV_SAMPLE_AGENT_WORKSPACE_DIR" \
  --worker-command ruby \
  --worker-command-arg "$A2O_DEV_SAMPLE_ROOT/tools/reference_validation/deterministic_worker.rb" \
  "$A2O_DEV_SAMPLE_PACKAGE"
