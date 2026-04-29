# A2O 0.5.51 Current Release Surface

This document describes the currently supported A2O 0.5.51 user surface and validation boundary.

Use it to confirm which features can be documented for users and what can be treated as validated at this release. For setup steps, read [10-quickstart.md](10-quickstart.md). For configuration fields, read [90-project-package-schema.md](90-project-package-schema.md).

## Supported Commands And Capabilities

- Host launcher install: `a2o host install`
- Version check: `a2o version`
- Host diagnosis: `a2o doctor`
- Project authoring and validation: `a2o project template`, `lint`, `validate`, `bootstrap`
- Worker helper commands: `a2o worker scaffold`, `a2o worker validate-result`
- Kanban service lifecycle and external Kanbalone checks: `a2o kanban up`, `doctor`, `url`
- Agent target detection and binary export: `a2o agent target`, `a2o agent install`
- Runtime container lifecycle: `a2o runtime up`, `down`
- Foreground runtime execution: `a2o runtime run-once`, `a2o runtime loop`
- Resident scheduler lifecycle: `a2o runtime resume`, `pause`, `status`
- Runtime diagnosis and recovery: `a2o runtime image-digest`, `doctor`, `watch-summary`, `logs [task-ref] --follow [--no-children]`, `describe-task <task-ref>`, `skill-feedback list`, `skill-feedback propose`, `reset-task <task-ref>`, `force-stop-task <task-ref> --dangerous`, `force-stop-run <run-ref> --dangerous`, `show-artifact <artifact-id>`
- Parent task log following keeps tracking the parent group when an active child finishes and work continues on another child or the parent task.
- `watch-summary` marks review rework/rejection as `x` while later clean review completion returns the review lane to the successful marker.
- Invalid worker results are preserved as salvage diagnostics after correction attempts are exhausted, so operators can inspect the rejected payload instead of losing it.
- Implementation retries after review rework receive prior review feedback in the worker runtime context.
- Operator-applied `blocked` labels are preserved during phase completion and keep the task blocked instead of being silently removed by runtime status publication.
- Clean parent review success results are normalized to a completed review disposition when the worker omits or partially fills `review_disposition`; explicitly contradictory dispositions are still rejected. Normalization now handles frozen worker payloads without crashing the scheduler.
- Multi-project runtime context groundwork scopes runtime storage, host logs/workspaces, scheduler pid/log files, temp files, and branch namespaces by resolved project key before manual multi-project lifecycle commands are enabled.
- Upgrade diagnosis: `a2o upgrade check`
- Single-file project package config: `project.yaml`
- Investigate decomposition MVP: `runtime.decomposition.investigate.command`, `runtime.decomposition.author.command`, `a2o runtime decomposition investigate`, `propose`, `review`, `create-children`, `status`, and `cleanup`
- Decomposition command UX: action-level help for `a2o runtime decomposition <action> --help`, plus direct external task sync/reconciliation for one-shot decomposition commands
- Gate-closed decomposition child creation reports `status=gate_closed` and `child_creation_result=not_attempted` without rendering an empty `success=` value
- Project runtime tuning fields for agent server connectivity: `runtime.agent_control_plane_connect_timeout`, `runtime.agent_control_plane_request_timeout`, `runtime.agent_control_plane_retry_count`, `runtime.agent_control_plane_retry_delay`
- Optional child/single review gate fields: `runtime.review_gate.child`, `runtime.review_gate.single`, `runtime.review_gate.skip_labels`, `runtime.review_gate.require_labels`
- External Kanbalone bootstrap fields: `--kanban-mode external`, `--kanban-url`, `--kanban-runtime-url`
- Runtime CLI overrides for agent server connectivity: `--agent-control-plane-connect-timeout`, `--agent-control-plane-request-timeout`, `--agent-control-plane-retries`, `--agent-control-plane-retry-delay`
- Host agent CLI and runtime profile fields for agent server connectivity: `--control-plane-connect-timeout`, `--control-plane-request-timeout`, `--control-plane-retries`, `--control-plane-retry-delay`, `control_plane_connect_timeout`, `control_plane_request_timeout`, `control_plane_retry_count`, `control_plane_retry_delay`
- Kanbalone adapter and bootstrap tooling, defaulting to Kanbalone `v0.9.24`
- Agent HTTP worker gateway, including claimed-job heartbeats
- Agent-materialized workspace mode
- Reference product packages for TypeScript, Go, Python, and multi-repo task templates
- GHCR runtime image tags: `latest`, `0.5.51`, and `sha-*`
- Tag releases also publish `latest`, so the released version tag and `latest` are expected to point to the same runtime image after release publication finishes.
- Local release gate: full RSpec suite, release package doctor, local RC host smoke, and real-task local RC smoke for runtime execution / worker launcher / scheduler / Kanban / env generation changes

## Migration Notes

- `a2o runtime start` and `a2o runtime stop` are no longer compatibility aliases. Use `a2o runtime resume` to resume the resident scheduler and `a2o runtime pause` to pause it after the current work. If the removed commands are invoked, A2O exits non-zero and prints `migration_required=true` with the replacement command.
- SoloBoard-era Kanbalone compatibility names are removed. Use `KANBAN_BACKEND=kanbalone`, `KANBALONE_BASE_URL`, `KANBALONE_API_TOKEN`, `--kanbalone-port`, `A2O_BUNDLE_KANBALONE_PORT`, and `A2O_KANBALONE_INTERNAL_URL`. Removed SoloBoard inputs fail with `migration_required=true` and the replacement name.
- Bundled Kanbalone data names changed from `<compose-project>_soloboard-data` / `soloboard.sqlite` to `<compose-project>_kanbalone-data` / `kanbalone.sqlite`. If the old volume exists and the new one does not, `a2o kanban up` fails with `migration_required=true` instead of silently creating an empty board. Copy or rename the existing Kanban data before starting the bundled service.
- Public `A3_*` environment fallbacks for runtime, agent, worker, and root utility configuration are removed where `A2O_*` replacements exist. Use `A2O_RUNTIME_IMAGE`, `A2O_COMPOSE_PROJECT`, `A2O_COMPOSE_FILE`, `A2O_RUNTIME_SERVICE`, `A2O_BUNDLE_AGENT_PORT`, `A2O_BUNDLE_STORAGE_DIR`, `A2O_AGENT_PACKAGE_DIR`, `A2O_AGENT_TOKEN`, `A2O_AGENT_TOKEN_FILE`, `A2O_AGENT_CONTROL_TOKEN`, `A2O_AGENT_CONTROL_TOKEN_FILE`, `A2O_AGENT_*`, `A2O_WORKER_*`, `A2O_WORKSPACE_ROOT`, `A2O_ROOT_DIR`, and `A2O_ROOT_*` root utility controls. Removed `A3_*` inputs fail with `migration_required=true` and the replacement name.
- `worker-runs.json` is no longer an activity state source. Operator diagnostics, cleanup, rerun readiness, reconcile, and watch-summary use `agent_jobs.json`; leftover `worker-runs.json` is reported with `migration_required=true`.
- Public agent package and host launcher artifacts use `a2o-agent` / `a2o` names. Release archives are named `a2o-agent-<version>-<os>-<arch>.tar.gz`, archives contain `a2o-agent`, host install writes `a2o` and `a2o-<os>-<arch>` only, shell installers remove stale `a3*` files from their install directory, and old package/cache environment names fail with `migration_required=true`. Runtime-image `a3 agent package ...` also fails with `migration_required=true`; use `a2o agent package ...`.

## Validation Scope

The reference product suite covers single-repo and multi-repo task flows through kanban, agent gateway, verification, merge, parent-child handling, runtime watch summary, describe-task diagnostics, and evidence persistence.

## Change Boundary

Open product work is tracked on the A2O kanban before implementation. External behavior changes require owner discussion before coding.
