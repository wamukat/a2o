# Single-File Project Package Schema

対象読者: A2O 設計者 / project package author / reviewer
文書種別: schema proposal

Status: implemented by `A2O#272`.

## Decision

The canonical project package config file should be `project.yaml`.

`manifest.yml` is deprecated as a separate author-facing file. Its former responsibilities moved into `project.yaml` under explicit runtime sections. This keeps the existing public package command shape, avoids introducing a second new name such as `a2o.yaml`, and removes the confusing split between "project config" and "manifest" for package authors.

The owner decisions for implementation are:

- `project.yaml` is the canonical file name.
- `manifest.yml` compatibility is not required for the new schema.
- User-facing schema and diagnostics should use A2O names. A3 names may remain only as internal compatibility details.
- Internal follow-up labels such as `a3:follow-up-child` should not be exposed in normal user-authored schema.

## Former Split

Before `A2O#272`, package authors had to understand two files:

- `project.yaml`: package metadata, kanban board, repo slots, agent prerequisites, runtime loop defaults.
- `manifest.yml`: runtime presets, merge behavior, project surface commands and skills through presets.

That split was unclear because both files described the same runtime package. `manifest.yml` also repeated the kanban project already present in `project.yaml`.

## Proposed Shape

```yaml
schema_version: 1

package:
  name: a2o-reference-typescript-api-web

kanban:
  provider: soloboard
  project: A2OReferenceTypeScript
  bootstrap: kanban/bootstrap.json
  selection:
    status: To do
    trigger_labels:
      - trigger:auto-implement
      - trigger:auto-parent

repos:
  app:
    path: ..
    role: product
    label: repo:app

agent:
  workspace_root: .work/a2o-agent/workspaces
  required_bins:
    - git
    - node
    - npm

runtime:
  live_ref: refs/heads/main
  max_steps: 20
  agent_attempts: 200
  presets:
    - base
  surface:
    implementation_skill: skills/implementation/base.md
    review_skill:
      default: skills/review/default.md
    verification_commands:
      - app/project-package/commands/verify.sh
    remediation_commands:
      - app/project-package/commands/format.sh
    workspace_hook: app/project-package/commands/bootstrap.sh
  merge:
    target: merge_to_live
    policy: ff_only
    target_ref: refs/heads/main

scenarios:
  - path: scenarios/001-add-work-order-filter.md
```

## Section Responsibilities

`schema_version` is required. Version `1` is the first single-file schema. The implementation should reject unsupported versions with a clear error.

`package` identifies the package, not the product repository. `package.name` replaces the current top-level scalar `project`.

`kanban` owns provider selection, board name, bootstrap config, task selection, and user-authored trigger labels used by the runtime bridge. The default provider remains `soloboard`. Internal coordination labels are runtime implementation details and should not be required in normal package schema.

`repos` defines stable repo slots. Slot keys are runtime identities. `path` is relative to the package directory unless absolute. `label` maps kanban labels to repo slots. If omitted, the implementation may derive `repo:<slot>`.

`agent` owns host-side workspace and toolchain requirements. `required_bins` remains declarative because the agent can validate prerequisites before work starts.

`runtime` owns execution defaults and the project surface that the Ruby runtime formerly read from `manifest.yml` plus presets.

`runtime.executor` owns the agent-side implementation/review command. It is required for packaged `a2o runtime run-once`, `runtime loop`, and `runtime start` when using the default `a2o-agent worker stdin-bundle` worker. A2O renders this public `project.yaml` section into an internal compatibility launcher config; users should not create a separate `launcher.json`.

The executor command receives the worker bundle on stdin and must write worker result JSON to `{{result_path}}`. Supported command placeholders are `{{result_path}}`, `{{schema_path}}`, `{{workspace_root}}`, and `{{a2o_root_dir}}`.

`runtime.presets` keeps the current preset model. Presets are still useful for common A2O behavior, but package-local overrides live beside the rest of the package config.

`runtime.surface` owns skills, verification commands, remediation commands, and workspace hook. Values may be scalar or variant maps, matching the current project surface resolver behavior.

`runtime.merge` owns merge target, policy, and target ref. Values may be scalar or variant maps, matching the current merge resolver behavior.

`scenarios` is optional metadata for validation and onboarding. A scenario entry points to a markdown task template. Runtime task selection still comes from kanban; scenarios are not auto-enqueued by default.

## Reference Product Examples

### TypeScript API/Web

```yaml
schema_version: 1
package:
  name: a2o-reference-typescript-api-web
kanban:
  provider: soloboard
  project: A2OReferenceTypeScript
  bootstrap: kanban/bootstrap.json
  selection:
    status: To do
repos:
  app:
    path: ..
    role: product
agent:
  required_bins: [git, node, npm]
runtime:
  live_ref: refs/heads/main
  max_steps: 20
  agent_attempts: 200
  executor:
    kind: command
    prompt_transport: stdin-bundle
    result: {mode: file}
    schema: {mode: file}
    default_profile:
      command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
      env: {}
    phase_profiles: {}
  presets: [base]
  surface:
    verification_commands:
      - app/project-package/commands/verify.sh
    remediation_commands:
      - app/project-package/commands/format.sh
    workspace_hook: app/project-package/commands/bootstrap.sh
  merge:
    target: merge_to_live
    policy: ff_only
    target_ref: refs/heads/main
```

### Go API/CLI

```yaml
schema_version: 1
package:
  name: a2o-reference-go-api-cli
kanban:
  provider: soloboard
  project: A2OReferenceGo
  bootstrap: kanban/bootstrap.json
  selection:
    status: To do
repos:
  app:
    path: ..
agent:
  required_bins: [git, go]
runtime:
  live_ref: refs/heads/main
  max_steps: 20
  agent_attempts: 200
  presets: [base]
  surface:
    verification_commands:
      - app/project-package/commands/verify.sh
    workspace_hook: app/project-package/commands/bootstrap.sh
  merge:
    target: merge_to_live
    policy: ff_only
    target_ref: refs/heads/main
```

### Python Service

```yaml
schema_version: 1
package:
  name: a2o-reference-python-service
kanban:
  provider: soloboard
  project: A2OReferencePython
  bootstrap: kanban/bootstrap.json
  selection:
    status: To do
repos:
  app:
    path: ..
agent:
  required_bins: [git, python3]
runtime:
  live_ref: refs/heads/main
  max_steps: 20
  agent_attempts: 200
  presets: [base]
  surface:
    verification_commands:
      - app/project-package/commands/verify.sh
    workspace_hook: app/project-package/commands/bootstrap.sh
  merge:
    target: merge_to_live
    policy: ff_only
    target_ref: refs/heads/main
```

### Multi-Repo Fixture

```yaml
schema_version: 1
package:
  name: a2o-reference-multi-repo
kanban:
  provider: soloboard
  project: A2OReferenceMultiRepo
  bootstrap: kanban/bootstrap.json
  selection:
    status: To do
repos:
  repo_alpha:
    path: ../repos/catalog-service
    role: product
    label: repo:catalog
  repo_beta:
    path: ../repos/storefront
    role: product
    label: repo:storefront
agent:
  required_bins: [git, node]
runtime:
  live_ref: refs/heads/main
  max_steps: 40
  agent_attempts: 300
  presets: [base]
  surface:
    review_skill:
      default: skills/review/default.md
      variants:
        task_kind:
          parent:
            repo_scope:
              both:
                phase:
                  review: skills/review/parent.md
    verification_commands:
      - "$A2O_ROOT_DIR/reference-products/multi-repo-fixture/project-package/commands/verify-all.sh"
    remediation_commands:
      - "$A2O_ROOT_DIR/reference-products/multi-repo-fixture/project-package/commands/format.sh"
    workspace_hook: reference-products/multi-repo-fixture
  merge:
    target:
      default: merge_to_live
      variants:
        task_kind:
          child:
            default: merge_to_parent
          parent:
            default: merge_to_live
    policy: ff_only
    target_ref:
      default: refs/heads/main
```

## Migration Status

`A2O#272` implements the migration:

1. A single loader reads `project.yaml` schema version `1`.
2. The runtime bridge derives internal runtime package data from `runtime.presets`, `runtime.surface`, and `runtime.merge`.
3. Reference product packages no longer contain `manifest.yml`.
4. The four reference packages use single-file `project.yaml`.
5. User docs and reference package docs no longer ask authors to create `manifest.yml`.
6. Package loading rejects old split files.
7. Package schema, docs, and normal diagnostics use A2O-facing names.

## Implementation Notes

- The new loader should reject packages that still require `manifest.yml`.
- The schema may translate A2O-facing fields into current internal Ruby runtime structures, but errors and docs should not ask users to author A3 names.
- Internal follow-up labels should have runtime defaults. Add advanced overrides only if a real product needs them later.
