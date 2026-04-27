# Quickstart

This document gives the shortest path from a first A2O install to having A2O process one kanban task. Read [00-overview.md](00-overview.md) first for the runtime model.

The goal is to get one task moving before you refine the project package. By the end, the host `a2o` command, kanban board, `a2o-agent`, and runtime instance all point at the same project.

## Target State

| Step | Result |
|---|---|
| Install the host launcher | The host can run `a2o` |
| Create a project package | A2O can read the product repositories, skills, commands, and kanban board |
| Bootstrap the runtime | `.work/a2o/runtime-instance.json` identifies the runtime instance |
| Start kanban | A2O board lanes and internal labels exist |
| Install the agent | `a2o-agent` can run jobs in the product environment |
| Create a task | A2O can pick up the task and record results in kanban, Git, and evidence |

## Prerequisites

- Docker is available.
- You have a product repository.
- You can place an A2O project package at the repository root.
- The environment that runs `a2o-agent` has the product toolchain and AI executor command.

Replace the template `your-ai-worker` with a real executable available to the agent. If it remains unchanged, `a2o doctor` or runtime execution will stop.

## 1. Install The Host Launcher

```sh
mkdir -p "$HOME/.local/bin" "$HOME/.local/share"

docker run --rm \
  -v "$HOME/.local:/install" \
  ghcr.io/wamukat/a2o-engine:0.5.38 \
  a2o host install \
    --output-dir /install/bin \
    --share-dir /install/share/a2o \
    --runtime-image ghcr.io/wamukat/a2o-engine:0.5.38

export PATH="$HOME/.local/bin:$PATH"
```

`a2o host install` extracts the host launcher and shared runtime assets from the runtime image. Ruby is not required on the host.

`docker run ... a2o --help` shows runtime-container entrypoint help, not the full host launcher command list. Use the installed `a2o` command after this point.

## 2. Create A Project Package

Place `project-package/` at the workspace root. This quickstart treats that directory as the standard package path.

```text
project-package/
  README.md
  project.yaml
  commands/
  skills/
  task-templates/
```

Start a new package from the template generator.

```sh
a2o project template \
  --package-name my-product \
  --kanban-project MyProduct \
  --language node \
  --executor-bin your-ai-worker \
  --with-skills \
  --output ./project-package/project.yaml
```

The command writes `project.yaml` and starter skill files. Replace `your-ai-worker` with the actual executor command before running the runtime.

For package design, read [20-project-package.md](20-project-package.md). For the full schema, read [90-project-package-schema.md](90-project-package-schema.md).

## 3. Check The Package

```sh
a2o project lint --package ./project-package
```

`project lint` checks `project.yaml`, command files, test fixture references, and internal names that leaked into user-facing locations. Fix `blocked` findings before runtime execution.

Only specify a separate config file when validating an explicit test profile.

```sh
a2o project validate --package ./project-package --config project-test.yaml
```

Keep normal `project.yaml` as the production configuration.

## 4. Bootstrap The Runtime Instance

```sh
a2o project bootstrap
```

`project bootstrap` writes `.work/a2o/runtime-instance.json`. Later `kanban`, `agent`, and `runtime` commands discover that file and use the same runtime instance.

Specify options only when you need different ports, a different Compose project name, or an external Kanbalone board.

```sh
a2o project bootstrap --compose-project my-product --kanbalone-port 3471 --agent-port 7394
```

```sh
a2o project bootstrap --kanban-mode external --kanban-url http://127.0.0.1:3470
```

## 5. Start Kanban

```sh
a2o kanban up
a2o kanban url
```

`kanban up` starts the bundled kanban service and provisions the lanes and internal labels A2O needs. In external mode, it validates the configured Kanbalone endpoint and provisions that board without starting the bundled service. `kanban url` prints the board URL.

The same Compose project reuses the existing board. If the board looks empty, check whether the Compose project or Docker volume changed. Runtime operations are covered in [30-operating-runtime.md](30-operating-runtime.md).

## 6. Install The Agent

```sh
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
```

`a2o-agent` runs executor commands, product toolchains, and Generative AI calls in the product environment. The default install path is `.work/a2o/agent/bin/a2o-agent`.

Run the full diagnosis next.

```sh
a2o doctor
```

Fix any `status=blocked` item before continuing.

## 7. Create One Task

1. Open the board with `a2o kanban url`.
2. Create a task from `project-package/task-templates/`.
3. Put the task in `project.yaml`'s `kanban.selection.status`; the default is `To do`.
4. Add a trigger label and, when needed, a repo label.

`a2o kanban up` prepares lanes and labels; it does not create work tasks.

## 8. Run A2O

For the first check, run one cycle.

```sh
a2o runtime run-once
```

For resident scheduling, use:

```sh
a2o runtime resume --interval 60s --agent-poll-interval 5s
a2o runtime status
a2o runtime pause
```

`runtime resume` begins task processing. `runtime pause` reserves scheduler stop after current work finishes. If you only need container lifecycle, use `a2o runtime up` / `a2o runtime down`.

## 9. Inspect The Result

```sh
a2o runtime watch-summary
a2o runtime describe-task <task-ref>
```

`watch-summary` shows task state, scheduler state, and active phases across the board. `describe-task` focuses on one task and shows run state, evidence, kanban comments, and log hints.

When a task has agent artifacts, `describe-task` prints an `agent_artifact_read` command.

```sh
a2o runtime show-artifact <artifact-id>
```

Board `Done` means A2O automated processing completed. Kanbalone `Resolved` / `done=true` is a separate final human confirmation state.

## If Something Fails

Start with:

```sh
a2o doctor
a2o runtime watch-summary
a2o runtime describe-task <task-ref>
```

Error categories, agent artifacts, and blocked task recovery are covered in [40-troubleshooting.md](40-troubleshooting.md).

## Next Documents

| Goal | Document |
|---|---|
| Understand project package design | [20-project-package.md](20-project-package.md) |
| Operate runtime / kanban / agent / image updates | [30-operating-runtime.md](30-operating-runtime.md) |
| Investigate blocked or failed tasks | [40-troubleshooting.md](40-troubleshooting.md) |
| Use multi-repo / parent-child tasks | [50-parent-child-task-flow.md](50-parent-child-task-flow.md) |
| Read every `project.yaml` field | [90-project-package-schema.md](90-project-package-schema.md) |
