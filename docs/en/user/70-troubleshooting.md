# Troubleshooting

This document explains where to look and what to fix when A2O execution stops. For day-to-day runtime commands, read [20-runtime-distribution.md](20-runtime-distribution.md).

The goal is to narrow failures through `doctor`, `status`, `watch-summary`, and `describe-task` instead of hunting through logs first. A2O classifies common failures as configuration errors, dirty repositories, executor failures, verification failures, merge conflicts, and runtime failures. Start from the category, then fix the related file or command.

## First Checks

```sh
a2o doctor
a2o runtime status
a2o runtime watch-summary
a2o runtime describe-task <task-ref>
```

`a2o doctor` checks the project package, executor configuration, required commands, repository cleanliness, agent install, kanban service, runtime container, and runtime image digest.

`runtime status` shows scheduler and runtime instance state. `watch-summary` shows the current position of multiple tasks. `describe-task` gathers one task's run, phases, workspace, evidence, kanban comments, and log hints.

## Symptom Guide

| Symptom | First command | Common cause | Fix |
|---|---|---|---|
| Tasks do not move | `a2o runtime status` | Scheduler or runtime container is stopped | `a2o runtime up`, `a2o runtime start` |
| Board looks empty | `a2o kanban doctor` | Compose project / Docker volume changed | Instance settings, Compose project, volume |
| Task is blocked | `a2o runtime describe-task <task-ref>` | Configuration error, dirty repo, executor failure, verification failure, merge conflict | The target shown by the error category |
| Docker credential helper blocks execution | `a2o doctor` | Docker config points to a missing credential helper | `credsStore` / `credHelpers`, or temporary `DOCKER_CONFIG` |
| Executor command does not start | `a2o doctor` | `your-ai-worker` was not replaced, binary is missing, credentials are missing | `project.yaml`, `agent.required_bins`, AI worker setup |
| Dirty repository blocks execution | `a2o runtime describe-task <task-ref>` | Uncommitted changes or generated files remain | Commit / stash / remove the listed files |
| Verification fails | `a2o runtime describe-task <task-ref>` | Product test failure, dependency issue, formatting issue, remediation failure | Project command, tests, dependencies |
| Merge fails | `a2o runtime describe-task <task-ref>` | Conflict, target ref moved, merge policy mismatch | Git branch, target ref, conflict |
| Image is not the expected one | `a2o runtime image-digest` | Pinned / local / running image references differ | Runtime image pin, pull, restart |

## Error Categories

A2O stderr and kanban comments include `error_category` and the next action.

| Category | Meaning | Fix |
|---|---|---|
| `configuration_error` | Project package or executor configuration is invalid | `project.yaml`, package path, schema, placeholders |
| `workspace_dirty` | A repository has uncommitted changes | Listed repository and files |
| `executor_failed` | AI worker or executor command failed | Executable, credentials, worker result JSON |
| `verification_failed` | Product verification failed | Tests, lint, dependencies, remediation command |
| `merge_conflict` | A merge conflict occurred | Conflict files, base branch state |
| `merge_failed` | Merge policy or target ref failed | Merge target, branch policy |
| `runtime_failed` | Docker, Compose, or runtime process failed | Printed command output, Docker state |

## Inspect One Task

```sh
a2o runtime describe-task <task-ref>
```

In `describe-task`, check:

- `latest_blocked` phase and summary
- `blocked_error_category`
- workspace and source refs
- evidence location
- kanban comment summary
- `agent_artifact_read` command

When agent artifacts exist, use the printed command to read executor stdout/stderr or worker results.

```sh
a2o runtime show-artifact <artifact-id>
```

If you need raw Generative AI transcripts in A2O output, configure the project executor or AI CLI to write the transcript to stdout, stderr, or the worker result. A2O stores that as an agent execution artifact.

## Fix A Dirty Repository

A2O stops on dirty repositories so it does not overwrite user changes.

1. Run `a2o runtime describe-task <task-ref>` and note the listed repository and files.
2. Commit changes that should be kept.
3. Stash temporary work.
4. Remove unwanted generated files.
5. Run `a2o doctor` to confirm the repository is clean enough for A2O.

If generated runtime files appear in the product repository root, check the project package and agent install paths. A2O-generated data should stay under `.work/a2o/`.

## Fix Docker Credential Helper Errors

When `a2o doctor` reports `docker_credential_helpers status=blocked`, Docker `credsStore` or `credHelpers` points to a `docker-credential-*` binary that is not available on the current host.

Check:

- `~/.docker/config.json`
- `$DOCKER_CONFIG/config.json` when `DOCKER_CONFIG` is set
- `credsStore`
- `credHelpers`
- whether `docker-credential-<name>` is on `PATH`

Install the helper if you use it. Otherwise, fix Docker `credsStore` / `credHelpers`.

For a temporary check with a minimal Docker config:

```sh
tmp_docker_config="$(mktemp -d)"
printf '{"auths":{}}\n' > "$tmp_docker_config/config.json"
DOCKER_CONFIG="$tmp_docker_config" a2o doctor
```

If that works, the cause is normal Docker configuration, not A2O.

## Recover A Blocked Task

```sh
a2o runtime reset-task <task-ref>
```

`reset-task` prints a dry-run recovery plan. It does not change kanban, runtime state, workspaces, or branches.

Recommended recovery:

1. Read the block reason, evidence, comments, and logs with `a2o runtime describe-task <task-ref>`.
2. Confirm related tasks are not running with `a2o runtime watch-summary`.
3. Fix the root cause: configuration, dirty repo, missing command, executor credential, verification failure, or merge conflict.
4. Explicitly commit, patch, or discard any manual workspace / branch changes that must be handled.
5. Run `a2o doctor`.
6. Run `a2o runtime run-once` or let the resident scheduler pick the task up again.

A2O updates block labels and blocked state when the next runtime attempt moves the task forward. In normal use, do not manually clear those through public `a2o` commands.

## Board Looks Empty

`a2o kanban up` uses a Compose project and Docker volume. When the Compose project changes, the same product can appear as a different board.

Check:

- Compose project in `.work/a2o/runtime-instance.json`
- Kanban / runtime instance information in `a2o runtime status`
- Service / board information in `a2o kanban doctor`
- Docker volume name

Decide whether to reuse the existing board, create a new board, back up data, or reset data before running `a2o kanban up`.

## Returning To Normal Operation

After fixing the cause, restart from broad diagnostics.

```sh
a2o doctor
a2o runtime status
a2o runtime watch-summary
```

If the scheduler is running, the next interval will pick up the task. Use `a2o runtime run-once` only when you want an immediate check.
