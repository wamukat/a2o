# A2O Reference Product Suite

対象読者: A2O runtime 実装者 / validation 設計者 / operator
文書種別: validation 方針

This document defines the owned sample products used for A2O core validation.

## Purpose

A2O must work across common product shapes rather than depending on one stack. The reference suite gives A2O small, reviewable projects that exercise runtime, agent, kanban, verification, merge, and parent-child flows.

## Suite Shape

| Product | Path | Purpose |
|---|---|---|
| TypeScript API/Web | `reference-products/typescript-api-web/` | API and browser UI in one repository |
| Go API/CLI | `reference-products/go-api-cli/` | server and CLI in one Go module |
| Python Service | `reference-products/python-service/` | lightweight service and Python verification |
| Multi-repo Fixture | `reference-products/multi-repo-fixture/` | parent-child and cross-repo validation |

Each product keeps its package at `project-package/`.

## Package Contract

Until `A2O#272` is implemented, each package includes:

- `README.md`
- `manifest.yml`
- `project.yaml`
- `kanban/bootstrap.json`
- `commands/`
- `skills/`
- `scenarios/`

The package must define a deterministic test or build command, agent prerequisites, editable source boundaries, and at least one scenario task that can be placed on the kanban board.

The target package schema is a single `project.yaml` file proposed in [42-single-file-project-package-schema.md](42-single-file-project-package-schema.md). Reference products should be migrated after owner approval.

## Validation Boundary

Core validation starts with the reference suite. If a runtime, workspace, worker gateway, verification, merge, or package preset change cannot be validated against at least one reference product, create a ticket to add or improve a reference scenario before relying on external product evidence.

External behavior changes found while improving the suite require owner discussion before implementation.

## Baseline

The latest recorded runtime baseline is [69-reference-runtime-baseline.md](69-reference-runtime-baseline.md). It proves that the suite can exercise:

- single-repo implementation / verification / merge
- multi-repo child implementation and verification
- child-to-parent merge
- parent review and verification
- parent live merge
- evidence persistence
