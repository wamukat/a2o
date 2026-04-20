# A2O Workspace And Repo Slot Model

This document defines workspace topology, repo slots, source synchronization, freshness, retention, and merge behavior.

Read it to understand which source A2O uses, which workspace it uses, and which branch receives the result. To turn AI execution results safely into Git changes, A2O must make source descriptors and repo slots explicit instead of relying on the incidental state of a local checkout.

## Runtime Placement

This document covers how Engine materializes Git sources into workspaces and publishes or merges them under a branch namespace while preparing phase jobs. Repo slots from the project package become runtime identifiers here, and `a2o-agent` uses those identifiers to operate on product repositories.

## Goals

- Keep product repository layout out of Engine core.
- Use stable repo slot aliases in runtime state and job payloads.
- Make source refs explicit before phase execution.
- Keep agent workspaces disposable.
- Preserve evidence for blocked and completed work.

## Repo Slots

A repo slot is a stable project package alias for a repository.

Example:

```yaml
repos:
  app:
    path: ..
    role: product
    label: repo:app
```

Runtime code should use `app`, not the local filesystem path, as the stable identifier.

## Source Aliases

The host launcher expands package repo slots into source aliases for the agent. The agent uses those aliases to materialize workspaces without parsing the project package.

## Workspace Kinds

### Ticket Workspace

Used for implementation. The agent materializes editable source for the task and publishes the result to the task work branch.

### Runtime Workspace

Used for review, verification, and merge. It is created from an explicit source descriptor and does not rely on incidental local checkout state.

## Branch Namespace

User-visible branch refs use A2O names:

```text
refs/heads/a2o/<instance>/work/<task>
refs/heads/a2o/<instance>/parent/<task>
```

The namespace includes the runtime instance so isolated boards can reuse small task numbers without colliding.

A2O writes user-visible branch refs under `refs/heads/a2o/...`. If `refs/heads/a3/...` refs are encountered, treat them as internal compatibility data rather than public branch names.

## Freshness

Workspace materialization must verify that a workspace matches the requested source descriptor. If it does not match, A2O recreates or refreshes it instead of silently reusing stale state.

Dirty source repositories fail fast, with the repo and file list included in diagnostics.

## Cleanup

Generated runtime output lives under `.work/a2o/`.

Agent metadata for materialized repo slots lives in A2O-managed metadata paths outside the product repo slot checkout. Product repo slots must not contain A2O-owned `.a3/slot.json` or `.a3/materialized.json` files.

Cleanup policy preserves evidence needed for blocked diagnosis and release validation while allowing disposable workspaces to be regenerated.

## Merge

Merge uses explicit source and target refs from the project package and runtime state.

Internal merge targets:

- child task to parent integration ref
- parent task to live target
- single task to live target

Merge policy is part of the project package. The default policy is fast-forward only unless the package explicitly declares another policy.
