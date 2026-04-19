# A2O Core Domain Model

This document defines the core domain objects and their responsibility boundaries.

## Model Principles

- Domain objects are immutable by default.
- Domain objects do not know product-specific file paths or commands.
- Infrastructure converts external systems into domain objects.
- Application services orchestrate domain rules without hiding state transitions.
- Public diagnostics should be derived from domain state, not reconstructed from logs.

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

Task status is the internal scheduler state, not the raw kanban lane. A2O maps between kanban lanes and internal status at the adapter boundary.

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

A task can have multiple runs. The current task state points at the active or latest relevant run.

## Phase

The phase describes the kind of work being performed:

- implementation
- review
- parent review
- verification
- remediation
- merge

Phase transitions are domain rules. They should not be encoded as scattered CLI conditionals.

## Scope Snapshot

A scope snapshot freezes the edit and verification scope for a run. It prevents later kanban label or package changes from changing the meaning of already recorded evidence.

## Source Descriptor

A source descriptor records where the run source came from:

- branch head
- detached commit
- parent integration ref
- live target ref

Workspace materialization and evidence inspection both depend on this descriptor.

## Artifact Owner

An artifact owner describes who owns evidence:

- task-owned evidence for single and child tasks
- parent-owned evidence for integration flows

The artifact owner includes a snapshot version so evidence can be tied back to the source state.

## Blocked Diagnosis

Blocked diagnosis is a structured summary for operator action. It should classify failures into categories such as:

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

JSON and SQLite are infrastructure choices behind the same repository contracts.
