# A2O 0.5.33 Current Release Surface

This document describes the currently supported A2O 0.5.33 user surface and validation boundary.

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
- Runtime diagnosis and recovery: `a2o runtime image-digest`, `doctor`, `watch-summary`, `logs [task-ref] --follow`, `describe-task <task-ref>`, `skill-feedback list`, `skill-feedback propose`, `reset-task <task-ref>`, `show-artifact <artifact-id>`
- Upgrade diagnosis: `a2o upgrade check`
- Single-file project package config: `project.yaml`
- Investigate decomposition MVP: `runtime.decomposition.investigate.command`, `runtime.decomposition.author.command`, `a2o runtime decomposition investigate`, `propose`, `review`, `create-children`, and `status`
- Project runtime tuning fields for agent server connectivity: `runtime.agent_control_plane_connect_timeout`, `runtime.agent_control_plane_request_timeout`, `runtime.agent_control_plane_retry_count`, `runtime.agent_control_plane_retry_delay`
- Optional child/single review gate fields: `runtime.review_gate.child`, `runtime.review_gate.single`, `runtime.review_gate.skip_labels`, `runtime.review_gate.require_labels`
- External Kanbalone bootstrap fields: `--kanban-mode external`, `--kanban-url`, `--kanban-runtime-url`
- Runtime CLI overrides for agent server connectivity: `--agent-control-plane-connect-timeout`, `--agent-control-plane-request-timeout`, `--agent-control-plane-retries`, `--agent-control-plane-retry-delay`
- Host agent CLI and runtime profile fields for agent server connectivity: `--control-plane-connect-timeout`, `--control-plane-request-timeout`, `--control-plane-retries`, `--control-plane-retry-delay`, `control_plane_connect_timeout`, `control_plane_request_timeout`, `control_plane_retry_count`, `control_plane_retry_delay`
- Kanbalone adapter and bootstrap tooling, defaulting to Kanbalone `v0.9.20`
- Agent HTTP worker gateway, including claimed-job heartbeats
- Agent-materialized workspace mode
- Reference product packages for TypeScript, Go, Python, and multi-repo task templates
- GHCR runtime image tags: `latest`, `0.5.33`, and `sha-*`
- Tag releases also publish `latest`, so the released version tag and `latest` are expected to point to the same runtime image after release publication finishes.
- Local release gate: full RSpec suite

## Validation Scope

The reference product suite covers single-repo and multi-repo task flows through kanban, agent gateway, verification, merge, parent-child handling, runtime watch summary, describe-task diagnostics, and evidence persistence.

## Change Boundary

Open product work is tracked on the A2O kanban before implementation. External behavior changes require owner discussion before coding.
