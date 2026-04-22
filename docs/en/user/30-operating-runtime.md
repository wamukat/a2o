# Operating The Runtime

This document explains the commands and state checks used in day-to-day A2O operation. For first setup, read [10-quickstart.md](10-quickstart.md). For package design, read [20-project-package.md](20-project-package.md). For failures, read [40-troubleshooting.md](40-troubleshooting.md).

The purpose is to treat A2O as a runtime that keeps watching kanban, not as a one-time container command. In normal operation, use the resident scheduler, then inspect state, run diagnostics, and update images from the commands below.

## Runtime Parts

A normal A2O setup has four parts.

| Part | Role | Main commands |
|---|---|---|
| Host launcher `a2o` | Controls the runtime image and instance from the host | `a2o project bootstrap`, `a2o kanban ...`, `a2o runtime ...` |
| A2O Engine | Selects kanban tasks, creates phase jobs, records results | `a2o runtime up`, `a2o runtime start`, `a2o runtime status` |
| `a2o-agent` | Runs jobs in the product environment and changes / verifies Git repositories | `a2o agent install` |
| Project package | Defines product repositories, skills, commands, and phases | `a2o project lint` |

The runtime instance is created from the project package. After bootstrap, `a2o kanban ...`, `a2o agent install`, and `a2o runtime ...` discover `.work/a2o/runtime-instance.json` and operate on the same instance.

```sh
a2o project bootstrap
```

Specify the package path only when it is not in the standard location.

```sh
a2o project bootstrap --package ./path/to/project-package
```

## Daily Operation

Normally, start kanban, install the agent, and start the scheduler.

```sh
a2o kanban up
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
a2o runtime up
a2o runtime start --interval 60s --agent-poll-interval 5s
```

Check state with:

```sh
a2o runtime status
a2o runtime watch-summary
a2o runtime logs <task-ref> --follow
```

`runtime status` shows scheduler state, runtime container state, kanban instance information, image digest, and the latest run. `runtime watch-summary` shows where board tasks currently are. `runtime logs` gathers per-phase logs for one task and prefers AI raw logs when they are available. With `--follow`, it follows the current phase AI raw live log first and falls back to the legacy live log when the worker does not expose AI raw output.

Use `describe-task` for one task.

```sh
a2o runtime describe-task <task-ref>
```

`describe-task` gathers run state, phases, workspace details, evidence, kanban comments, log hints, and agent artifact commands.

## Scheduler And Manual Runs

Use the resident scheduler for normal operation.

```sh
a2o runtime start --interval 60s --agent-poll-interval 5s
a2o runtime status
a2o runtime stop
```

`runtime start` runs task processing as a resident scheduler. `runtime stop` stops the scheduler. `runtime status` confirms whether the scheduler is running, whether the runtime image matches expectations, and how the latest run ended.

Use `runtime run-once` for manual checks, test runs, or a retry after fixing a root cause.

```sh
a2o runtime run-once
```

Use `runtime up` / `down` only for container lifecycle. They do not start the scheduler.

```sh
a2o runtime up
a2o runtime down
```

## Kanban Operation

Kanban is the input queue A2O Engine reads.

```sh
a2o kanban up
a2o kanban doctor
a2o kanban url
```

`kanban up` starts the bundled kanban service and provisions the lanes and internal labels A2O needs. Users should not hand-author A2O-managed lanes or internal labels in the project package.

The same Compose project reuses the existing board. If the Compose project or Docker volume changes, the same product can appear to have a different empty board. When that happens, first check instance settings, Compose project, and volume through `a2o runtime status` and `a2o kanban doctor`.

## Agent Operation

`a2o-agent` is the binary that runs jobs from A2O Engine in the product environment. The standard install path is `.work/a2o/agent/bin/a2o-agent`.

```sh
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
```

Agent workspaces, materialized data, and launcher settings stay under `.work/a2o/agent/`. Avoid putting generated runtime files in product repository roots.

Declare the product toolchain and AI executor in `agent.required_bins`. A placeholder such as `your-ai-worker` will block `a2o doctor` or runtime execution until replaced.

## Image Updates And Digests

Before using a new runtime image, inspect the planned change.

```sh
a2o upgrade check
a2o runtime image-digest
```

`upgrade check` does not pull images, restart services, or edit files. It reports the host launcher version, initialized instance config, runtime image digest, agent install state, and the next commands to run.

To pull and restart the runtime image:

```sh
a2o runtime up --pull
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
a2o doctor
a2o runtime status
```

`runtime image-digest` compares configured pinned references, local `latest`, and the running container image. If they differ, decide which image should be active before restarting with `a2o runtime up`.

## Diagnostics

Move from broad checks to narrow checks.

| Need | Command |
|---|---|
| Package, agent, kanban, runtime, and image check | `a2o doctor` |
| Runtime container and scheduler state | `a2o runtime status` |
| Runtime-specific diagnosis | `a2o runtime doctor` |
| Kanban service and board state | `a2o kanban doctor` |
| Progress across tasks | `a2o runtime watch-summary` |
| Aggregated task logs | `a2o runtime logs <task-ref>` |
| One task's run / evidence / logs | `a2o runtime describe-task <task-ref>` |

For blocked tasks, dirty repositories, executor failures, verification failures, and merge issues, read [40-troubleshooting.md](40-troubleshooting.md).
