# A2O Workspace And Repo Slot Model

Audience: A2O designers, implementers
Document type: workspace model

This document defines workspace topology, repo slots, source synchronization, freshness, retention, and merge behavior.

## Goals

- Keep product repository layout out of Engine core.
- Use stable repo slot aliases in runtime state and job payloads.
- Make source refs explicit before phase execution.
- Keep agent workspaces disposable.
- Preserve enough evidence to inspect blocked and completed work.

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

The host launcher expands package repo slots into agent source aliases. The agent uses those aliases to materialize workspaces without needing to parse the project package.

## Workspace Kinds

### Ticket Workspace

Used for implementation. The agent materializes editable source for the task and publishes the result to the task work branch.

### Runtime Workspace

Used for review, verification, and merge. It is created from explicit source descriptors and should not rely on incidental local checkout state.

## Branch Namespace

User-visible branch refs should use A2O names:

```text
refs/heads/a2o/<instance>/work/<task>
refs/heads/a2o/<instance>/parent/<task>
```

The namespace includes the runtime instance so isolated boards can reuse small task numbers without colliding.

Legacy `refs/heads/a3/...` refs may exist as compatibility data, but new public behavior should use A2O refs.

## Freshness

Workspace materialization must verify that the workspace matches the requested source descriptor. If it does not, A2O should recreate or refresh it rather than silently reusing stale state.

Dirty source repositories should fail fast with the repo and file list included in diagnostics.

## Cleanup

Generated runtime output should live under `.work/a2o/`.

Agent metadata inside materialized workspaces may still use `.a3/` as internal compatibility data. Users should not edit those files.

Cleanup policy should preserve evidence needed for blocked diagnosis and release validation while allowing disposable workspaces to be regenerated.

## Merge

Merge uses explicit source and target refs from the project package and runtime state.

Supported merge targets:

- child to parent integration ref
- parent to live target
- single task to live target

Merge policy is part of the project package. The default policy is fast-forward only unless the package explicitly allows another policy.
