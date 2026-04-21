# Evidence And Rerun Diagnosis

This document defines how A2O records evidence, diagnoses blocked runs, and supports rerun decisions.

Read this to understand what state must remain available after a failed run so an operator can inspect it safely and rerun it when appropriate. Evidence is not just log retention; it is investigation data that ties together the task, run, phase, source state, and artifact owner.

## Runtime Placement

This document covers the runtime state produced after phase jobs complete or block. Evidence is a runtime-owned record attached to a task, run, phase, source descriptor, and artifact owner. It lets operators diagnose task state after transient logs or disposable workspaces are gone.

## Goals

- Make completed and blocked runs inspectable after transient logs disappear.
- Tie evidence to source descriptors and artifact owners.
- Classify failures so operators know what to fix.
- Preserve enough state to rerun safely without guessing.

## Evidence

Evidence records should include:

- task ref
- run ref
- phase
- workspace kind
- source descriptor
- artifact owner
- snapshot version
- command summary
- output artifact references
- terminal outcome

Evidence is runtime-owned. It should not require users to inspect generated workspace metadata directly.

## Artifact Owner

An artifact owner identifies the task or parent task that owns the evidence. The snapshot version ties that evidence to a source state.

Single and child tasks usually own task-scoped evidence. Parent integration flows may own parent-scoped evidence.

## Blocked Diagnosis

Blocked diagnosis converts low-level errors into operator categories:

- `configuration_error`
- `workspace_dirty`
- `executor_failed`
- `verification_failed`
- `merge_conflict`
- `merge_failed`
- `runtime_failed`

Diagnostics should include:

- category
- short summary
- affected repo or phase
- relevant file list when available
- next action
- pointers to `a2o runtime describe-task <task-ref>` and logs

## Rerun Policy

A rerun is safe only when A2O can determine:

- which task and phase failed
- which source descriptor was used
- whether the workspace is clean or can be recreated
- whether the previous failure is terminal or retryable
- whether evidence from the previous run should remain attached

Reruns should not silently overwrite evidence. New attempts produce new runs.

## Operator Inspection

Operators should start with:

```sh
a2o runtime watch-summary
a2o runtime describe-task <task-ref>
```

`watch-summary` gives the multi-task overview. `describe-task` aggregates task state, run state, evidence, kanban comments, and log hints for one task.

## Retention

Terminal workspace cleanup is separate from evidence retention. A2O may remove disposable workspaces while keeping enough evidence and blocked diagnosis data to inspect the run.

Generated state belongs under `.work/a2o/` unless it is internal workspace metadata.

## Traceability Boundary

For operator diagnosis, A2O treats these layers differently:

- durable sources of truth:
  - run and phase state
  - blocked diagnosis
  - the evidence summary shown by `describe-task`
  - agent artifacts such as `combined-log` and worker results
  - kanban comments
- supporting logs kept for diagnosis:
  - host agent log
  - runtime and server operator logs
- temporary state that may still be cleared:
  - pid files
  - exit files
  - transient logs regenerated for the current process
  - disposable workspaces, subject to the evidence retention policy

`a2o runtime describe-task <task-ref>` should lead operators to durable evidence first and supporting logs second. A scheduler restart must not erase the host-agent history needed to distinguish configuration problems from runtime or executor failures.
