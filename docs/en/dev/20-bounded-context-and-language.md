# A2O Bounded Contexts And Language

This document defines the vocabulary and Bounded Context used by A2O. Domain, workspace, evidence, and implementation documents use these terms.

Read it to keep the same word from taking on multiple meanings. Task, run, phase, workspace, and evidence are A2O decision units, separate from UI labels and implementation convenience names. For state transitions, read [30-core-domain-model.md](30-core-domain-model.md). For workspace details, read [40-workspace-and-repo-slot-model.md](40-workspace-and-repo-slot-model.md).

## Runtime Placement

This document aligns the language used from the moment a kanban task is imported by the scheduler, through Engine creating phase jobs, `a2o-agent` executing jobs, and evidence and kanban state being updated. When other design documents mention task, run, phase, workspace, project package, or operator inspection, read those terms through this Bounded Context.

## Design Stance

A2O names concepts by domain meaning, not by incidental code structure.

- Define meaning first, then align class / module / file names.
- Do not add phase-specific rescue branches to domain language.
- Public vocabulary uses A2O names. A3 may remain only as an internal compatibility name.

## Context Map

### Task Execution Context

Owns:

- task kind
- phase
- run
- terminal outcome
- rerun eligibility

This context decides where a task is in the lifecycle and what can happen next.

### Workspace Context

Owns:

- workspace kind
- repo slot
- source descriptor
- artifact owner
- freshness and cleanup policy

This context decides what source tree a phase uses and how work is materialized.

### Project Package Context

Owns:

- package identity
- kanban board name
- repo slots and labels
- agent prerequisites
- phase commands and skills
- verification and remediation commands
- merge defaults

This context is the product-owned configuration surface.

### Operator Inspection Context

Owns:

- evidence summary
- blocked-run diagnosis
- watch summary
- `describe-task` output
- runtime status and `doctor` output

This context explains what happened and what the operator should do next.

## Core Terms

### Task

A unit of work imported from kanban or created as part of a parent-child flow.

### Task Kind

- `single`: a standalone task.
- `child`: a task that changes one part of a parent scope.
- `parent`: an integration task that owns child aggregation, parent review, parent verification, and live merge.

### Phase

The execution step currently being processed. The public project package uses:

- `implementation`
- `review`
- `parent_review`
- `verification`
- `remediation`
- `merge`

### Run

One attempt to execute one task phase. A run records phase, workspace, source descriptor, result, evidence, and blocked details.

### Terminal Outcome

The final result of a run, such as success, blocked, failed verification, merge conflict, or executor failure.

### Repo Slot

A stable project package alias for a repository, such as `app`, `repo_alpha`, or `repo_beta`. Runtime behavior uses repo slots rather than hard-coded product paths.

### Workspace Kind

- `ticket_workspace`: used for implementation work.
- `runtime_workspace`: used for review, verification, and merge.

### Evidence

Structured records and artifacts that let an operator inspect what happened without relying on transient logs.

### Source Descriptor

The source ref and workspace kind that define what code a run used.

### Artifact Owner

The task or parent task that owns an evidence snapshot.

## Public Naming

Users should see A2O names:

- `A2O`
- `a2o`
- `a2o-agent`
- `.work/a2o`
- `refs/heads/a2o/...`

Internal compatibility names may remain in implementation details and diagnostics only when necessary.
