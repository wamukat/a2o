# A2O Reference Product Suite

Audience: A2O runtime implementers, validation designers, operators
Document type: validation policy

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

Each package includes:

- `README.md`
- `project.yaml`
- `commands/`
- `skills/`
- `task-templates/`

The package must define deterministic test or build commands, agent prerequisites, editable source boundaries, and at least one task template that can be placed on the kanban board.

`project.yaml` is the single author-facing package config file. It owns package identity, kanban selection, repo slots, agent prerequisites, runtime surface commands, and merge defaults.

## Validation Boundary

Core validation starts with the reference suite. If a runtime, workspace, worker gateway, verification, merge, or package preset change cannot be validated against at least one reference product, create a ticket to add or improve a reference task template before relying on external product evidence.

External behavior changes found while improving the suite require owner discussion before implementation.

## Release Validation Scope

The suite is the release validation target for:

- single-repo implementation / verification / merge
- multi-repo child implementation and verification
- child-to-parent merge
- parent review and verification
- parent live merge
- runtime watch summary and task diagnostics
- evidence persistence

Validation runs may use deterministic workers to isolate Engine behavior from model variability, but the exercised surfaces remain real: kanban pickup and transitions, branch namespace creation, workspace materialization, worker gateway transport, agent-side publication, verification commands, merge, and evidence persistence.
