# Agent Worker Gateway Design

The agent worker gateway lets A2O delegate project-local work to an `a2o-agent` process running on the host or in a project dev environment. This keeps project toolchains out of the runtime image while preserving Engine-owned orchestration.

## Goals

- Keep runtime images small and product-agnostic.
- Run project commands where project toolchains and credentials already exist.
- Keep Engine scheduling, evidence, phase transitions, and merge orchestration centralized.
- Use a clear request/result protocol between Engine and agent.

## Runtime Shape

The runtime container starts an internal control plane. `a2o-agent` polls that control plane, receives a job, materializes the requested workspace, runs the command, uploads artifacts, and posts the result.

The host launcher installs the agent with:

```sh
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
```

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

Older `A3_*` names are internal compatibility aliases only. Do not use them in project packages, templates, or user-facing diagnostics.

## Workspace Materialization

The agent owns materialized job workspaces under the configured workspace root. A2O provides source aliases and source descriptors. The agent must not invent source refs.

Dirty or stale workspaces should fail fast or be recreated according to the cleanup/freshness policy.

## Verification

Verification commands are project package responsibility. Engine only interprets their result and records evidence.

## Validation

The reference product suite validates:

- TypeScript single-repo implementation / verification / merge
- Go single-repo implementation / verification / merge
- Python single-repo implementation / verification / merge
- Multi-repo parent-child implementation, child merge, parent review, parent verification, and parent merge

See [90-reference-product-suite.md](90-reference-product-suite.md).
