# A2O User Manual

A2O starts from kanban tasks and manages workspace creation, agent execution, verification, merge, and evidence recording. Users prepare a project package and operate the runtime through public A2O commands.

## Getting Started

### 1. Install The Host Launcher

```sh
mkdir -p "$HOME/.local/bin" "$HOME/.local/share"

docker run --rm \
  -v "$HOME/.local:/install" \
  ghcr.io/wamukat/a2o-engine:0.5.0 \
  a2o host install \
    --output-dir /install/bin \
    --share-dir /install/share/a2o \
    --runtime-image ghcr.io/wamukat/a2o-engine:0.5.0

export PATH="$HOME/.local/bin:$PATH"
```

`a2o host install` extracts the host launcher and shared runtime assets from the runtime image. Ruby is not required on the host.

`docker run ... a2o --help` is runtime-container entrypoint help, not the full host launcher command list. Setup commands such as `a2o project template` are available from the installed host launcher.

### 2. Add A Project Package

Place `project-package/` or `a2o-project/` at the workspace root.

```text
project-package/
  README.md
  project.yaml
  commands/
  skills/
  task-templates/
```

Start new packages from the template generator:

```sh
a2o project template \
  --package-name my-product \
  --kanban-project MyProduct \
  --language node \
  --executor-bin your-ai-worker \
  --output ./project-package/project.yaml
```

`--output` writes only `project.yaml`. The kanban board name, repo labels, and human project labels are authored in `project.yaml`. A2O-owned lanes and internal labels are provisioned by `a2o kanban up`.

`your-ai-worker` is a placeholder. Replace it with an executor binary that exists where `a2o-agent` runs. A2O writes this value into `agent.required_bins` and `runtime.phases.*.executor.command`; if it is not replaced, `a2o doctor` or runtime execution will stop with a missing command.

For package design decisions, see [50-project-package-authoring-guide.md](50-project-package-authoring-guide.md).

### 3. Start With Four Commands

```sh
a2o project bootstrap
a2o kanban up
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
a2o runtime run-once
```

`a2o project bootstrap` writes `.work/a2o/runtime-instance.json`. Later `kanban`, `agent`, and `runtime` commands discover the same runtime instance.

Before `run-once`, create one runnable task on the board:

1. Open the board with `a2o kanban url`.
2. Create a task from `project-package/task-templates/`.
3. Put the task in `project.yaml`'s `kanban.selection.status`; the default is `To do`.
4. Add a trigger label and, when needed, a repo label.

Inspect task state and evidence with:

```sh
a2o runtime watch-summary
a2o runtime describe-task <task-ref>
```

## `project.yaml`

`project.yaml` is the only public project package config file. A2O reads package metadata, kanban bootstrap data, repo slots, agent prerequisites, runtime phase commands, and merge defaults from it.

Minimal single-repo shape:

```yaml
schema_version: 1
package:
  name: my-product
kanban:
  project: MyProduct
  selection:
    status: To do
repos:
  app:
    path: ..
    role: product
    label: repo:app
agent:
  workspace_root: .work/a2o/agent/workspaces
  required_bins:
    - git
    - node
    - npm
    - your-ai-worker
runtime:
  max_steps: 20
  agent_attempts: 200
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - your-ai-worker
          - "--schema"
          - "{{schema_path}}"
          - "--result"
          - "{{result_path}}"
    review:
      skill: skills/review/default.md
      executor:
        command:
          - your-ai-worker
          - "--schema"
          - "{{schema_path}}"
          - "--result"
          - "{{result_path}}"
    verification:
      commands:
        - app/project-package/commands/verify.sh
    remediation:
      commands:
        - app/project-package/commands/format.sh
    merge:
      target: merge_to_live
      policy: ff_only
      target_ref: refs/heads/main
```

Implementation and review executors receive a stdin-bundle worker request and write worker result JSON to `{{result_path}}`.

Executor placeholders:

- `{{schema_path}}`
- `{{result_path}}`
- `{{workspace_root}}`
- `{{a2o_root_dir}}`
- `{{root_dir}}`

Verification and remediation placeholders:

- `{{workspace_root}}`
- `{{a2o_root_dir}}`
- `{{root_dir}}`

`agent.required_bins` lists commands that must exist where the agent runs, including language toolchains and AI/helper executors.

## Generated Files

New bootstrap writes runtime instance config to `.work/a2o/runtime-instance.json`. Agent install and runtime execution also place host agent binaries, launcher config, and agent workspaces under `.work/a2o/`.

`.work/a2o/` is regenerable runtime output and normally should not be committed. Users manage the project package, product source, and optional Taskfile.

Legacy runtime instance config may be read for compatibility, but new bootstrap does not write it.

## Kanban

```sh
a2o kanban up
a2o kanban doctor
a2o kanban url
```

`a2o kanban up` shows the compose project, SoloBoard data volume, reuse/create mode, and backup hint. The same compose project reuses the existing board. A different compose project creates a different Docker volume, so the board may look empty.

A2O provisions required lanes and internal labels. Repo labels are authored in `repos.<slot>.label`. Human project labels are authored in `kanban.labels`.

Use `a2o kanban up --fresh-board` when an empty board is required. If an existing volume is present, the command stops rather than reusing it.

## Agent

```sh
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
a2o doctor
```

`a2o agent install` exports `a2o-agent` from the runtime image. The canonical path is `.work/a2o/agent/bin/a2o-agent`.

`a2o doctor` checks project package config, executor config, required commands, repo cleanliness, agent install, kanban volume/service, runtime container, and runtime image digest.

## Runtime

Container lifecycle only:

```sh
a2o runtime up
a2o runtime down
```

One cycle:

```sh
a2o runtime run-once
```

Foreground loop:

```sh
a2o runtime loop --interval 60s
```

Resident scheduler:

```sh
a2o runtime start --interval 60s
a2o runtime status
a2o runtime stop
```

Runtime diagnosis:

```sh
a2o runtime doctor
a2o runtime watch-summary
a2o runtime describe-task <task-ref>
```

`runtime watch-summary` is the multi-task overview. Use `runtime describe-task <task-ref>` for one task's run, evidence, comments, and log hints.

## Troubleshooting

A2O CLI stderr and kanban comments include `error_category` and remediation guidance.

| Category | What to fix |
|---|---|
| `configuration_error` | Fix `project.yaml`, executor config, package path, or schema. |
| `workspace_dirty` | Commit, stash, or remove the listed dirty repo files. |
| `executor_failed` | Check executor binary, credentials, required toolchain, and worker result JSON. |
| `verification_failed` | Check product tests, lint, dependencies, or remediation command output. |
| `merge_conflict` | Resolve merge conflict or base branch state. |
| `merge_failed` | Check merge target ref and branch policy. |
| `runtime_failed` | Check Docker, compose, runtime processes, and printed command output. |

Diagnostic entrypoints:

```sh
a2o doctor
a2o kanban doctor
a2o runtime doctor
a2o runtime watch-summary
a2o runtime describe-task <task-ref>
```

`Done` in the board is A2O's automation-complete state. SoloBoard's `Resolved` flag is a separate human-confirmation state. It is normal for API snapshots to show `status=Done` with `done=false` until a human marks the task resolved.

## Runtime Image Updates

A2O 0.5.0 uses:

```text
ghcr.io/wamukat/a2o-engine:0.5.0
```

For shared product packages, release smoke, or multi-user boards, pin by digest after validation.

Recommended update flow:

```sh
a2o runtime up --pull
a2o runtime image-digest
a2o doctor
```

Record the printed `runtime_image_digest=...` in the product package Taskfile, env file, or deployment note.

## Multi-Repo Packages

Multi-repo packages define one repo slot per repository:

```yaml
repos:
  repo_alpha:
    path: ../repos/catalog-service
    role: product
    label: repo:catalog
  repo_beta:
    path: ../repos/storefront
    role: product
    label: repo:storefront
```

Tasks use repo labels to select target slots. Parent-child flows let child tasks work in individual repos while the parent task handles integration review, verification, and merge.
