# Operating The Runtime

This document explains the commands and state checks used in day-to-day A2O operation. For first setup, read [10-quickstart.md](10-quickstart.md). For package design, read [20-project-package.md](20-project-package.md). For failures, read [40-troubleshooting.md](40-troubleshooting.md).

The purpose is to treat A2O as a runtime that keeps watching kanban, not as a one-time container command. In normal operation, use the resident scheduler, then inspect state, run diagnostics, and update images from the commands below.

## Runtime Parts

A normal A2O setup has four parts.

| Part | Role | Main commands |
|---|---|---|
| Host launcher `a2o` | Controls the runtime image and instance from the host | `a2o project bootstrap`, `a2o kanban ...`, `a2o runtime ...` |
| A2O Engine | Selects kanban tasks, creates phase jobs, records results | `a2o runtime up`, `a2o runtime resume`, `a2o runtime status` |
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
a2o runtime resume --interval 60s --agent-poll-interval 5s
```

Check state with:

```sh
a2o runtime status
a2o runtime watch-summary
a2o runtime logs [task-ref] --follow
a2o runtime clear-logs --task-ref <task-ref>
a2o runtime metrics list --format json
a2o runtime metrics summary --group-by parent
a2o runtime metrics trends --group-by parent
a2o runtime skill-feedback list
a2o runtime skill-feedback propose --format ticket
```

`runtime status` shows scheduler state, runtime container state, kanban instance information, image digest, and the latest run. `runtime watch-summary` shows where board tasks currently are. `runtime logs` gathers per-phase logs for one task and prefers AI raw logs when they are available. With `--follow`, it follows the current phase AI raw live log first and falls back to the legacy live log when the worker does not expose AI raw output. If no task ref is given and exactly one task is running, `runtime logs --follow` selects that task automatically; use `--index N` when multiple tasks are running. When a parent task ref is given, `--follow` selects an active child when one is running; pass `--no-children` to follow the parent task itself. `runtime metrics list` exports stored task metrics as JSON or CSV. `runtime metrics summary` prints a compact rollup by task, or by parent with `--group-by parent`. `runtime metrics trends` prints derived indicators such as rework rate, average verification time, token-per-line-added, test failure rate, and unsupported indicators when source data is missing. `runtime skill-feedback list` lists reusable skill improvement candidates reported by workers, with `--state`, `--target`, and `--group` for filtering and duplicate grouping. `runtime skill-feedback propose` converts candidates into a ticket body or draft patch, but it does not modify skill files automatically. `runtime clear-logs` is the explicit cleanup surface for persisted analysis logs; it is dry-run by default and only deletes when `--apply` is added.

Use `describe-task` for one task.

```sh
a2o runtime describe-task <task-ref>
```

`describe-task` gathers run state, phases, workspace details, evidence, kanban comments, log hints, skill feedback summaries, and agent artifact commands.
When a task is blocked by an invalid worker result, `describe-task` prints `execution_validation_error=` or `blocked_validation_error=` lines with the worker result schema errors. `watch-summary --details` also includes `validation_error=` detail lines for blocked tasks.
When stdin-bundle workers keep returning invalid JSON or schema-invalid JSON after the built-in correction loop, A2O stores an invalid-result salvage record under the worker metadata directory at `invalid-worker-results/latest.json` and keeps the newest five salvage records there. The salvage record includes the raw or parsed invalid output, structured validation errors, task/run/phase, and the schema name. A later retry in the same workspace receives that latest salvage record in the worker bundle as `previous_invalid_worker_result`; invalid results still never advance task state.
When Kanbalone exposes reason metadata for blocked or clarification labels, `describe-task` includes it in the kanban task section and `watch-summary --details` prints `kanban_tag_reason=` detail lines. Normal `watch-summary` output does not show those extra lines.
When a worker cannot continue because the product requirement is ambiguous or conflicting, it can return `clarification_request`. A2O stores the task as `needs_clarification`, adds the `needs:clarification` kanban label, posts the question/context/options/impact as a kanban comment, and excludes the task from scheduling until the requester answers and the clarification label/state is cleared.

For prompt / skill / worker-command PDCA, A2O now persists:

- `combined-log`
- `ai-raw-log`
- `execution-metadata` with start / finish / duration

These persisted analysis artifacts are separate from terminal workspace cleanup.

## Scheduler And Manual Runs

Use the resident scheduler for normal operation.

```sh
a2o runtime resume --interval 60s --agent-poll-interval 5s
a2o runtime status
a2o runtime pause
```

`runtime resume` runs task processing as a resident scheduler. `runtime pause` reserves scheduler pause after current work finishes and prevents the next task from starting. `runtime status` confirms whether the scheduler is running, whether it is paused, whether the runtime image matches expectations, and how the latest run ended.

For a multi-project installation, project lifecycle commands can target one project or every registered project:

```sh
a2o runtime resume --project <key>
a2o runtime resume --all-projects
a2o runtime status --all-projects
a2o runtime pause --all-projects
```

`--all-projects` starts or pauses one scheduler per project. Each project still runs at most one active task; intra-project parallel task execution is not enabled by this mode. Every registered project must resolve to a unique `compose_project` and host `agent_port`; A2O fails before scheduler startup if those lifecycle surfaces collide.

If an already-running task must be interrupted immediately, use the dangerous force-stop commands:

```sh
a2o runtime force-stop-task <task-ref> --dangerous
a2o runtime force-stop-run <run-ref> --dangerous
```

These commands mark the active run terminal with outcome `cancelled` by default, clear the task's runtime binding so it can be scheduled again, mark matching agent jobs stale, clean the internal runtime workspace when present, and best-effort stop runtime execution processes. Use them only for intentional operator intervention after preserving any manual work that matters.

Scheduler selection follows the kanban board as the source of truth.

- Tasks in `Resolved` or `Archived` are not scheduling targets and do not appear in `watch-summary`.
- Tasks in `Done` remain visible and remain part of the current board view until a human resolves them.
- An unresolved kanban blocker keeps the blocked task out of runnable selection.
- A task labeled `needs:clarification` is imported as `needs_clarification` and is not runnable; this is requester-input waiting, not a technical `blocked` failure.
- Parent/child gating and sibling ordering still apply in addition to kanban blockers.
- When a parent ticket has child tasks, A2O treats that parent-child set as one selection group.
- When multiple parent groups are present, A2O first chooses the group whose parent ticket has the highest priority.
- Inside the selected parent group, A2O chooses the highest-priority child task that is currently runnable.
- Unresolved blockers on the parent ticket are inherited by its child tasks. While a parent blocker remains unresolved, children in that parent group are not runnable.
- If a parent appears blocked, child tasks in that group are also outside scheduler selection.
- When runnable candidates are not part of parent groups, the scheduler chooses the highest kanban priority first.
- If priorities are equal, the scheduler breaks ties by task ref.

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

Bundled Kanbalone is the default. If multiple A2O projects should share one independent Kanbalone instance while keeping separate boards per project, create the runtime instance in external mode:

```sh
a2o project bootstrap --kanban-mode external --kanban-url http://127.0.0.1:3470
```

External mode stores the public board URL in the runtime instance and, when needed, a separate runtime URL for the Docker container. Use `--kanban-runtime-url` when the runtime container cannot reach the host URL directly. For loopback host URLs, A2O derives a `host.docker.internal` runtime URL unless one is explicitly provided. In this mode, `kanban up`, `kanban doctor`, `runtime status`, `runtime doctor`, and `doctor` check the external endpoint; `runtime up` starts the A2O runtime container without managing the bundled Kanbalone container.

The same Compose project reuses the existing board. If the Compose project or Docker volume changes, the same product can appear to have a different empty board. When that happens, first check instance settings, Compose project, and volume through `a2o runtime status` and `a2o kanban doctor`.

## Requirement Decomposition

Use `trigger:investigate` when the kanban ticket is a broad requirement that should be investigated and split before implementation. A source ticket with `trigger:investigate` belongs to the decomposition domain even if it also has `trigger:auto-implement`; remove `trigger:investigate` before treating the source ticket itself as ordinary implementation work. The source ticket does not need a `repo:*` scope label because it is not an implementation target. A2O treats the source ticket as a requirement artifact, not as the implementation parent. In normal operation, implementation should happen on the generated parent/child task tree, and those implementation children should carry the appropriate repo labels.

The runtime scheduler started by `a2o runtime resume` automatically checks the decomposition queue before ordinary implementation work. A single `a2o runtime run-once` cycle does the same check, so label-driven decomposition does not require manually running the individual `a2o runtime decomposition ...` phase commands.

The automatic decomposition flow is:

1. A2O selects a source ticket with `trigger:investigate`.
2. A2O moves the source ticket to `In progress`; the project-owned investigation command runs and records investigation evidence.
3. The proposal author creates a normalized child-ticket proposal.
4. A2O moves the source ticket to `In review`; proposal review decides whether the proposal is eligible for draft child creation.
5. Eligible proposals create a separate generated implementation parent ticket, record the requirement source in the generated parent description and source-ticket comments, and create draft child tickets labeled `a2o:draft-child` under that generated parent.
6. A2O marks the source ticket decomposed and moves it to `Done`.

A2O also creates a `related` relation from the requirement source ticket to the generated implementation parent. The relation is traceability only; it does not make the source ticket runnable and it does not replace child `subtask` relations or dependency `blocked` relations. External Kanbalone deployments must run Kanbalone v0.9.25 or newer for this decomposition relation path.

Each completed stage leaves a short comment on the source ticket so operators can follow progress from Kanban. `a2o runtime watch-summary` also shows `trigger:investigate` source tickets in its `Decomposition` section; before any evidence is written they appear as `state=queued`, and after evidence exists the section shows the current decomposition state, disposition, and proposal fingerprint when available. Detailed evidence is stored under the runtime storage directory in `decomposition-evidence/<task>/`; `a2o runtime decomposition status <task-ref>` shows the current decomposition evidence summary, and `a2o runtime describe-task <task-ref>` gives the broader task state.

`a2o runtime logs <task-ref>` is useful for decomposition source tickets as well. If the source ticket has no ordinary implementation/review log artifacts, the command falls back to the decomposition status output and evidence paths. `--follow` is not a live decomposition stream; when no ordinary task run is active it prints the decomposition fallback and reports that live follow is not supported for that source-ticket state.

Draft children are planning artifacts. They are visible on the board under the generated parent, but they are not runnable until a human accepts them by adding `trigger:auto-implement`. Operators can edit the generated parent and child title, body, labels, blockers, and scope before acceptance. Removing `a2o:draft-child` is optional metadata cleanup; the runnable gate is `trigger:auto-implement`. After accepted child work is ready, add `trigger:auto-parent` to the generated parent, not to the original requirement source ticket.

Useful commands:

```sh
a2o runtime decomposition status <task-ref>
a2o runtime decomposition accept-drafts <parent-ref> --child <child-ref> --remove-draft-label --parent-auto
a2o runtime decomposition cleanup <task-ref> --dry-run
a2o runtime decomposition cleanup <task-ref> --apply
```

`accept-drafts` is a convenience for accepting one or more draft children in a single operation. It pauses scheduler processing while it changes child and generated-parent labels, then resumes the scheduler only after the batch succeeds. If the scheduler was already paused, it stays paused. If the batch fails after A2O paused the scheduler, A2O leaves it paused for inspection.

For package configuration, including `runtime.decomposition.investigate.command`, `runtime.decomposition.author.command`, and decomposition prompt/template layers, read [90-project-package-schema.md](90-project-package-schema.md#runtime-decomposition).

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
| Aggregated task logs | `a2o runtime logs <task-ref>` or `a2o runtime logs --follow` |
| One task's run / evidence / logs | `a2o runtime describe-task <task-ref>` |
| Immediately interrupt an active run | `a2o runtime force-stop-task <task-ref> --dangerous` |
| Metrics export | `a2o runtime metrics list --format json` or `a2o runtime metrics list --format csv` |
| Metrics rollup | `a2o runtime metrics summary --group-by parent` |
| Metrics trends | `a2o runtime metrics trends --group-by parent --format json` |
| Reusable skill improvement candidates | `a2o runtime skill-feedback list` |
| Draft a skill improvement proposal | `a2o runtime skill-feedback propose --format ticket` |

For blocked tasks, dirty repositories, executor failures, verification failures, and merge issues, read [40-troubleshooting.md](40-troubleshooting.md).
