# Implementation Status

対象読者: A2O 利用者 / 実装者 / reviewer
文書種別: current status

Date: 2026-04-17

## Ready

- Host launcher install: `a2o host install`
- Project bootstrap: `a2o project bootstrap --package DIR`
- Kanban service lifecycle: `a2o kanban up`, `doctor`, `url`
- Agent binary export: `a2o agent install`
- Foreground runtime execution: `a2o runtime run-once`, `a2o runtime loop`
- Resident scheduler lifecycle: `a2o runtime start`, `stop`, `status`
- Runtime diagnosis: `a2o runtime doctor`
- SoloBoard adapter and bootstrap tooling
- Agent HTTP worker gateway
- Agent-materialized workspace mode
- Reference product packages for TypeScript, Go, Python, and multi-repo scenarios
- Full RSpec release gate passing locally

## Current Baseline

[69-reference-runtime-baseline.md](69-reference-runtime-baseline.md) records the latest reference suite runtime proof. It validates single-repo and multi-repo task flows through kanban, agent gateway, verification, merge, and evidence persistence.

## Productization Gaps

- `A2O#268` Published image smoke: release candidate validation should be repeated against the published GHCR image, not only a local equivalent.
- `A2O#269` Package schema consolidation: `manifest.yml` and `project.yaml` responsibilities should be documented and validated consistently.
- `A2O#270` User-facing diagnostics: internal A3 names can remain, but normal manuals should avoid requiring users to author them.

Each gap should be tracked as a kanban ticket before implementation. External behavior changes require owner discussion before coding.
