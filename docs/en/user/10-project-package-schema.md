# Single-File Project Package Schema

The canonical project package config file is `project.yaml`.

`manifest.yml` is not part of the public 0.5.0 package format. Runtime responsibilities live in `project.yaml` under explicit runtime sections. This keeps the package surface small and avoids a split between "project config" and "manifest".

For authoring decisions and responsibility boundaries, see [50-project-package-authoring-guide.md](50-project-package-authoring-guide.md).

## Rules

- `project.yaml` is the canonical file name.
- `schema_version: 1` is required.
- User-facing schema and diagnostics use A2O names.
- A3 names may remain only as internal compatibility details.
- Internal follow-up labels and runtime coordination labels are provisioned by A2O, not authored by users.

## Minimal Shape

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
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    review:
      skill: skills/review/default.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
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

## Package

`package.name` is the stable package identity. It should be filesystem and branch-ref safe.

## Kanban

`kanban.project` is the board/project name. A2O provisions required lanes and internal labels through `a2o kanban up`.

`kanban.selection.status` selects runnable tasks. The default is `To do`.

Project-specific human labels can be declared in `kanban.labels`. A2O-owned trigger and internal coordination labels should not be user-authored unless a future public option requires it.

## Repos

Each repo slot defines:

- local path
- role
- kanban label

Repo slots are stable aliases used in runtime state and agent job payloads.

## Agent

`agent.required_bins` lists commands that must exist where `a2o-agent` runs.

`agent.workspace_root` is disposable runtime output. It should normally live under `.work/a2o/`.

## Runtime Phases

`runtime.phases.<phase>.skill` points to a package skill file.

`runtime.phases.<phase>.executor.command` is the agent-side command for implementation and review phases. Supported placeholders:

- `{{schema_path}}`
- `{{result_path}}`
- `{{workspace_root}}`
- `{{a2o_root_dir}}`
- `{{root_dir}}`

Verification and remediation commands support:

- `{{workspace_root}}`
- `{{a2o_root_dir}}`
- `{{root_dir}}`

Project commands should treat the worker request JSON and `A2O_*` worker environment variables as the stable contract. Do not read private `.a3` metadata files or generated `launcher.json` files from package scripts.

## Template Generator

New packages should start from the generator instead of hand-writing executor blocks.

```sh
a2o project template \
  --package-name my-product \
  --kanban-project MyProduct \
  --language node \
  --executor-bin your-ai-worker \
  --with-skills \
  --output ./project-package/project.yaml
```

`--output` writes `project.yaml`. `--with-skills` also writes starter implementation, review, and parent review skills and adds a `parent_review` phase that references the generated parent skill. Kanban bootstrap data is derived from `kanban.project`, `kanban.labels`, and `repos.<slot>.label`. A2O-owned lanes and internal coordination labels are provisioned by `a2o kanban up`.

## Current Status

1. One loader reads `project.yaml` schema version `1`.
2. Runtime bridge data is derived from `runtime.phases`.
3. Reference product packages use only `project.yaml`.
4. Package loading rejects old split files.
5. Schema, docs, and diagnostics use A2O-facing names.
