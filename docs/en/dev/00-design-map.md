# A2O Design Map

This document explains what each design document covers and the recommended reading order.

## Goals

- Keep domain, application, infrastructure, and project surface responsibilities separate.
- Keep product-specific rescue branches and workspace assumptions out of Engine core.
- Make the boundary between public A2O surfaces and internal compatibility names explicit.
- Treat the reference product suite as the canonical core validation target.

## Architecture Overview

```mermaid
flowchart TB
  subgraph User["User"]
    Task["Writes kanban tasks\nwhat to change, constraints, priority"]
    Package["Maintains project package\nproject.yaml, skills, commands"]
    Command["Runs a2o commands\nbootstrap, kanban up, runtime start/run-once/status"]
    Observe["Checks results\nkanban status, comments, workspace evidence"]
  end

  subgraph CLI["a2o CLI"]
    Bootstrap["Creates and validates runtime setup\nproject template, project bootstrap, project lint"]
    KanbanOps["Starts and opens kanban\nboard, lanes, required tags"]
    RuntimeOps["Controls execution\nrun-once for one cycle, start for scheduler, status for inspection"]
  end

  subgraph Engine["A2O Engine"]
    Config["Loads project.yaml\nrepos, phases, commands, scheduler settings"]
    SkillUse["Loads phase skills\nimplementation, review, remediation, merge"]
    Scheduler["Scheduler\nselects runnable kanban work and advances phases"]
    Execute["Executes phase commands\nthrough a2o-agent and project commands"]
    Report["Records results\nevidence, summaries, kanban comments, status changes"]
  end

  Kanban["Kanban\nwork queue and visible state"]
  Workspace["Product workspace\nrepo slots, branches, evidence files"]

  Task --> Kanban
  Package --> Bootstrap
  Command --> Bootstrap
  Command --> KanbanOps
  Command --> RuntimeOps
  Bootstrap --> Config
  KanbanOps --> Kanban
  RuntimeOps --> Scheduler
  Kanban --> Scheduler
  Config --> Scheduler
  SkillUse --> Scheduler
  Package --> Config
  Package --> SkillUse
  Scheduler --> Execute
  Execute --> Workspace
  Execute --> Report
  Report --> Workspace
  Report --> Kanban
  Kanban --> Observe
  Workspace --> Observe
```

The user gives A2O three main inputs: kanban tasks, a project package, and CLI commands. `project.yaml` defines the project shape, phase commands, repository slots, and scheduler settings. Skills define how each phase should be handled. The CLI prepares the runtime and kanban surface, then starts either one-shot execution or the resident scheduler. The Engine combines kanban work, `project.yaml`, and skills, executes the configured phases, and writes the outcome back as workspace evidence and kanban-visible status.

## Documents

### 0. User Path

- [../user/00-user-quickstart.md](../user/00-user-quickstart.md)

The user manual for installing and operating A2O.

### 1. Engineering Discipline

- [10-engineering-rulebook.md](10-engineering-rulebook.md)

Rules for immutability, TDD, refactoring, and avoiding shortcut fixes.

### 2. Language and Bounded Contexts

- [20-bounded-context-and-language.md](20-bounded-context-and-language.md)

Defines task kind, phase, workspace, repo slot, evidence, and other core vocabulary.

### 3. Core Domain Model

- [30-core-domain-model.md](30-core-domain-model.md)

Defines aggregates, entities, value objects, and state transitions.

### 4. Workspace / Repo Slot / Lifecycle

- [40-workspace-and-repo-slot-model.md](40-workspace-and-repo-slot-model.md)

Defines fixed repo slots, synchronization, freshness, retention, garbage collection, and merge workspaces.

### 5. Project Surface

- [50-project-surface.md](50-project-surface.md)
- [55-project-script-contract.md](55-project-script-contract.md)
- [../user/10-project-package-schema.md](../user/10-project-package-schema.md)
- [80-runtime-extension-boundary.md](80-runtime-extension-boundary.md)

Defines the project package schema, project script contract, repo slots, verification, and extension boundaries.

### 6. Evidence / Rerun / Blocked Diagnosis

- [60-evidence-and-rerun-diagnosis.md](60-evidence-and-rerun-diagnosis.md)

Defines the internal evidence model for review, merge, rerun, and blocked-run diagnosis.

### 7. Runtime Distribution

- [../user/20-runtime-distribution.md](../user/20-runtime-distribution.md)
- [70-agent-worker-gateway-design.md](70-agent-worker-gateway-design.md)
- [../user/30-runtime-naming-boundary.md](../user/30-runtime-naming-boundary.md)

Defines the Docker runtime image, host launcher, bundled kanban service, agent gateway, and internal compatibility names.

### 8. Reference Validation

- [90-reference-product-suite.md](90-reference-product-suite.md)

Defines the sample products and the release validation scope.

### 9. Release Status

- [../user/40-release-status.md](../user/40-release-status.md)

Summarizes the public surface and validation status for A2O 0.5.2.

### 10. Kanban Adapter Boundary

- [95-kanban-adapter-boundary.md](95-kanban-adapter-boundary.md)

Defines the current kanban command contract and the adapter boundary for future native implementations.
