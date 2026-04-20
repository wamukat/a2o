# A2O 0.5.6 Current Release Surface

This document describes the currently supported A2O 0.5.6 user surface and validation boundary.

Use it to confirm which features can be documented for users and what can be treated as validated at this release. For setup steps, read [10-quickstart.md](10-quickstart.md). For configuration fields, read [90-project-package-schema.md](90-project-package-schema.md).

## Supported Commands And Capabilities

- Host launcher install: `a2o host install`
- Version check: `a2o version`
- Host diagnosis: `a2o doctor`
- Project authoring and validation: `a2o project template`, `lint`, `validate`, `bootstrap`
- Worker helper commands: `a2o worker scaffold`, `a2o worker validate-result`
- Kanban service lifecycle: `a2o kanban up`, `doctor`, `url`
- Agent target detection and binary export: `a2o agent target`, `a2o agent install`
- Runtime container lifecycle: `a2o runtime up`, `down`
- Foreground runtime execution: `a2o runtime run-once`, `a2o runtime loop`
- Resident scheduler lifecycle: `a2o runtime start`, `stop`, `status`
- Runtime diagnosis and recovery: `a2o runtime image-digest`, `doctor`, `watch-summary`, `describe-task <task-ref>`, `reset-task <task-ref>`, `show-artifact <artifact-id>`
- Upgrade diagnosis: `a2o upgrade check`
- Single-file project package config: `project.yaml`
- Kanbalone adapter and bootstrap tooling, defaulting to Kanbalone `v0.9.16`
- Agent HTTP worker gateway
- Agent-materialized workspace mode
- Reference product packages for TypeScript, Go, Python, and multi-repo task templates
- GHCR runtime image tags: `latest`, `0.5.6`, and `sha-*`
- Local release gate: full RSpec suite

## Validation Scope

The reference product suite covers single-repo and multi-repo task flows through kanban, agent gateway, verification, merge, parent-child handling, runtime watch summary, describe-task diagnostics, and evidence persistence.

## Change Boundary

Open product work is tracked on the A2O kanban before implementation. External behavior changes require owner discussion before coding.
