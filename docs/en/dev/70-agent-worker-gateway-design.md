# Agent Worker Gateway Design

The agent worker gateway lets A2O delegate project-local work to an `a2o-agent` process running on the host or in a project dev environment. This keeps project toolchains out of the runtime image while preserving Engine-owned orchestration.

Read this when deciding whether behavior belongs in the Engine or in the agent. The Engine owns lifecycle and evidence; the agent owns command execution inside a product environment. This separation lets A2O manage task progress without knowing every product toolchain.

## Runtime Placement

This document covers the boundary where the Engine publishes a prepared phase job to `a2o-agent`, the agent uses project tools or AI workers to modify or verify a materialized workspace, and the result and artifacts return to the Engine. The Engine owns lifecycle and evidence; the agent owns command execution in the workspace.

## Goals

- Keep runtime images small and product-agnostic.
- Run project commands where project toolchains and credentials already exist.
- Keep Engine scheduling, evidence, phase transitions, and merge orchestration centralized.
- Use a clear request/result protocol between Engine and agent.

## Flow

1. The Engine creates or refreshes the workspace for a task phase.
2. The Engine publishes an agent job through the control plane.
3. `a2o-agent` accepts the job, materializes the requested repo slots, and runs the declared command.
4. The agent uploads structured result metadata and declared artifacts.
5. The Engine parses the result, records evidence, transitions the task, and publishes or merges refs when the phase allows it.

The host launcher installs the agent with:

```sh
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
```

## Workspace Metadata

An agent job includes:

- job id
- task ref
- run ref
- phase
- parent/child relationship when relevant
- workspace id and branch namespace
- repo slot aliases
- source refs and support refs
- command profile and expected working directory
- artifact upload rules

The agent must not infer product-specific paths from global defaults. Paths come from the job payload and the project package that produced it.

## Command Execution

Project commands run on the agent side. The boundary treats implementation workers, verification commands, merge commands, and diagnostic commands through the same control-plane shape.

Command execution records:

- terminal outcome
- exit code
- stdout/stderr summary
- changed files when the phase publishes edits
- declared evidence artifacts
- structured failure reason for blocked tasks
- optional `skill_feedback` for collecting skill improvement candidates. This is not a contract for workers to edit skill files directly.

Verification commands are the project package's responsibility. The Engine only interprets success, failure, blocked reason, and evidence metadata.

## Job Contract

A job includes:

- job id
- task ref
- run ref
- phase
- working directory
- command
- environment
- source aliases
- workspace request
- artifact upload rules

The agent returns:

- terminal outcome
- exit code
- stdout/stderr summary
- uploaded artifact refs
- workspace descriptor
- publication refs

## Worker Protocol Environment

Project package commands should use the A2O worker environment names:

- `A2O_WORKER_REQUEST_PATH`: JSON request bundle for the current job.
- `A2O_WORKER_RESULT_PATH`: path where the command writes the final worker result JSON.
- `A2O_WORKSPACE_ROOT`: materialized workspace root for the job.
- `A2O_WORKER_LAUNCHER_CONFIG_PATH`: generated launcher config used by the bundled stdin worker.

`A3_*` names are internal compatibility aliases only. Do not use them in project packages, templates, or user-facing diagnostics.

## Workspace Materialization

- Repo slot names are stable package aliases such as `app`, `repo_alpha`, and `repo_beta`.
- User-visible branch refs created by the current runtime use `refs/heads/a2o/...`. Treat `refs/heads/a3/...` refs as internal compatibility data.
- Agent workspace paths are disposable and must not become durable project configuration.
- Generated runtime metadata stays under `.work/a2o/agent/` managed paths, not inside product repo slots. A2O metadata should not leak into source trees users commit.

## Verification

The reference product suite validates the gateway boundary through real package commands and deterministic fixtures when model variability should be isolated.

## Validation Scope

The reference product suite validates:

- TypeScript single-repo implementation / verification / merge
- Go single-repo implementation / verification / merge
- Python single-repo implementation / verification / merge
- Multi-repo parent-child implementation, child merge, parent review, parent verification, and parent merge

See [90-reference-product-suite.md](90-reference-product-suite.md).
