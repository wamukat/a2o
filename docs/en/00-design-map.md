# A2O Design Map

Audience: A2O designers, implementers, reviewers
Document type: design navigation

This document explains what each design document covers and the recommended reading order.

## Goals

- Keep domain, application, infrastructure, and project surface responsibilities separate.
- Keep product-specific rescue branches and workspace assumptions out of Engine core.
- Make the boundary between public A2O surfaces and internal compatibility names explicit.
- Treat the reference product suite as the canonical core validation target.

## Documents

### 0. User Path

- [90-user-quickstart.md](90-user-quickstart.md)

The user manual for installing and operating A2O.

### 1. Engineering Discipline

- [05-engineering-rulebook.md](05-engineering-rulebook.md)

Rules for immutability, TDD, refactoring, and avoiding shortcut fixes.

### 2. Language and Bounded Contexts

- [10-bounded-context-and-language.md](10-bounded-context-and-language.md)

Defines task kind, phase, workspace, repo slot, evidence, and other core vocabulary.

### 3. Core Domain Model

- [20-core-domain-model.md](20-core-domain-model.md)

Defines aggregates, entities, value objects, and state transitions.

### 4. Workspace / Repo Slot / Lifecycle

- [30-workspace-and-repo-slot-model.md](30-workspace-and-repo-slot-model.md)

Defines fixed repo slots, synchronization, freshness, retention, garbage collection, and merge workspaces.

### 5. Project Surface

- [40-project-surface-and-presets.md](40-project-surface-and-presets.md)
- [42-single-file-project-package-schema.md](42-single-file-project-package-schema.md)
- [64-runtime-extension-boundary.md](64-runtime-extension-boundary.md)

Defines the project package schema, project commands, repo slots, verification, and extension boundaries.

### 6. Evidence / Rerun / Blocked Diagnosis

- [50-evidence-and-rerun-diagnosis.md](50-evidence-and-rerun-diagnosis.md)

Defines the internal evidence model for review, merge, rerun, and blocked-run diagnosis.

### 7. Runtime Distribution

- [60-container-distribution-and-project-runtime.md](60-container-distribution-and-project-runtime.md)
- [62-agent-worker-gateway-design.md](62-agent-worker-gateway-design.md)
- [66-runtime-naming-boundary.md](66-runtime-naming-boundary.md)

Defines the Docker runtime image, host launcher, bundled kanban service, agent gateway, and internal compatibility names.

### 8. Reference Validation

- [68-reference-product-suite.md](68-reference-product-suite.md)

Defines the sample products and the release validation scope.

### 9. Release Status

- [70-implementation-status.md](70-implementation-status.md)

Summarizes the public surface and validation status for A2O 0.5.0.
