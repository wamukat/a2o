# A2O 0.5.5 Current Release Surface

This document describes the currently supported A2O 0.5.5 user surface and validation boundary.

Use it to confirm which features can be documented for users and what can be treated as validated at this release. For setup steps, read [00-user-quickstart.md](00-user-quickstart.md). For configuration fields, read [10-project-package-schema.md](10-project-package-schema.md).

## Supported Commands And Capabilities

- Host launcher install: `a2o host install`
- Project bootstrap: `a2o project bootstrap`, optional `--package DIR`
- Kanban service lifecycle: `a2o kanban up`, `doctor`, `url`
- Agent binary export: `a2o agent install`
- Runtime container lifecycle: `a2o runtime up`, `down`
- Foreground runtime execution: `a2o runtime run-once`, `a2o runtime loop`
- Resident scheduler lifecycle: `a2o runtime start`, `stop`, `status`
- Runtime diagnosis: `a2o runtime doctor`, `a2o runtime watch-summary`, `a2o runtime describe-task <task-ref>`
- Upgrade diagnosis: `a2o upgrade check`
- Single-file project package config: `project.yaml`
- SoloBoard adapter and bootstrap tooling, defaulting to SoloBoard `v0.9.15`
- Agent HTTP worker gateway
- Agent-materialized workspace mode
- Reference product packages for TypeScript, Go, Python, and multi-repo task templates
- GHCR runtime image tags: `latest`, `0.5.5`, and `sha-*`
- Local release gate: full RSpec suite

## Validation Scope

The reference product suite covers single-repo and multi-repo task flows through kanban, agent gateway, verification, merge, parent-child handling, runtime watch summary, describe-task diagnostics, and evidence persistence.

## Change Boundary

Open product work is tracked on the A2O kanban before implementation. External behavior changes require owner discussion before coding.
