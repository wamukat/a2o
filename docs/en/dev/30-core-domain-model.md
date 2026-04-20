# A2O Core Domain Model

This document defines A2O's core domain objects and responsibility boundaries.

Read it to understand that A2O decides the next action from domain state, not from kanban display state or logs. Use it when deciding where to hold tasks, runs, phases, and evidence, and which state transitions are allowed. For external-system boundaries, read [95-kanban-adapter-boundary.md](95-kanban-adapter-boundary.md). For agent execution, read [70-agent-worker-gateway-design.md](70-agent-worker-gateway-design.md).

## Runtime Placement

This document covers how Engine represents the task lifecycle after the scheduler selects a kanban task for processing. Task, run, phase, scope snapshot, source descriptor, and evidence are the source of truth for decisions before and after handing a job to `a2o-agent`, and for returning results to kanban and evidence storage.

## Model Principles

- Domain objects are immutable by default.
- Domain objects do not know product-specific file paths or commands.
- Infrastructure converts external systems into domain objects.
- Application services advance domain rules without hiding state transitions.
- Public diagnostics are derived from domain state, not reconstructed from transient logs.

## Task

`Task` is the central aggregate root.

It owns:

- `ref`
- `kind`
- `status`
- `current_run_ref`
- `parent_ref`
- edit scope
- verification scope

Task status is internal scheduler state, not the kanban lane itself. A2O maps between kanban lanes and internal state at the adapter boundary.

## Run

`Run` represents one attempt to execute one task phase.

It owns:

- run ref
- task ref
- phase
- workspace kind
- source descriptor
- scope snapshot
- artifact owner
- state
- terminal outcome
- blocked diagnosis summary

A task can have multiple runs. The current task state points to the active run or the latest relevant run.

## Phase

A phase describes the kind of work currently being performed.

- `implementation`
- `review`
- `parent_review`
- `verification`
- `remediation`
- `merge`

Phase transitions are domain rules. They must not be scattered across CLI conditionals.

## Scope Snapshot

A scope snapshot freezes the edit scope and verification scope for a run. This prevents later kanban label or package changes from changing the meaning of already recorded evidence.

## Source Descriptor

A source descriptor records where the source used by a run came from.

- branch head
- detached commit
- parent integration ref
- live target ref

Workspace materialization and evidence inspection both depend on this descriptor.

## Artifact Owner

An artifact owner describes who owns evidence.

- task-owned evidence for single and child tasks
- parent-owned evidence for integration flows

The artifact owner includes a snapshot version so evidence can be tied back to the source state.

## Blocked Diagnosis

Blocked diagnosis is a structured summary for operator action. It classifies failures into categories such as:

- configuration error
- workspace dirty
- executor failed
- verification failed
- merge conflict
- merge failed
- runtime failed

## Repositories

Domain repositories provide persistence contracts for:

- tasks
- runs
- scheduler state
- scheduler cycles
- evidence and blocked diagnosis read models

JSON and SQLite are infrastructure implementation choices behind the same repository contracts.
