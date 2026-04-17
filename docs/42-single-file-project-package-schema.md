# Single-File Project Package Schema

対象読者: A2O 設計者 / project package author / reviewer
文書種別: schema proposal

Status: proposal for owner review. Implementation is tracked by `A2O#272`.

## Decision

The canonical project package config file should be `project.yaml`.

`manifest.yml` should be deprecated as a separate author-facing file. Its current responsibilities should move into `project.yaml` under explicit runtime sections. This keeps the existing public package command shape, avoids introducing a second new name such as `a2o.yaml`, and removes the confusing split between "project config" and "manifest" for package authors.

Implementation must not start until the owner accepts this schema direction.

## Current Split

Today package authors must understand two files:

- `project.yaml`: package metadata, kanban board, repo slots, agent prerequisites, runtime loop defaults.
- `manifest.yml`: runtime presets, merge behavior, project surface commands and skills through presets.

That split is unclear because both files describe the same runtime package. `manifest.yml` also repeats the kanban project already present in `project.yaml`.

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
    follow_up_label: a3:follow-up-child

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

`kanban` owns provider selection, board name, bootstrap config, task selection, and labels used by the runtime bridge. The default provider remains `soloboard`.

`repos` defines stable repo slots. Slot keys are runtime identities. `path` is relative to the package directory unless absolute. `label` maps kanban labels to repo slots. If omitted, the implementation may derive `repo:<slot>`.

`agent` owns host-side workspace and toolchain requirements. `required_bins` remains declarative because the agent can validate prerequisites before work starts.

`runtime` owns execution defaults and the project surface that the Ruby runtime currently reads from `manifest.yml` plus presets.

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
      - "$A3_ROOT_DIR/reference-products/multi-repo-fixture/project-package/commands/verify-all.sh"
    remediation_commands:
      - "$A3_ROOT_DIR/reference-products/multi-repo-fixture/project-package/commands/format.sh"
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

## Migration Plan

1. Add a single loader that reads `project.yaml` schema version `1`.
2. Teach the runtime bridge to derive the old manifest payload from `runtime.presets`, `runtime.surface`, and `runtime.merge`.
3. Keep temporary read compatibility for existing two-file packages only during migration.
4. Convert the four reference packages to single-file `project.yaml`.
5. Update user docs and reference package docs to remove `manifest.yml`.
6. Add validation errors for packages that provide both single-file fields and legacy `manifest.yml` after the compatibility window.
7. Remove legacy `manifest.yml` support in a later cleanup ticket if compatibility is no longer needed.

`A2O#272` should implement steps 1 through 5. Steps 6 and 7 can be part of `A2O#272` only if the owner accepts a breaking change immediately; otherwise create a follow-up compatibility-removal ticket.

## Owner Discussion Points

- Confirm `project.yaml` as the canonical file name instead of `a2o.yaml`.
- Confirm whether `manifest.yml` compatibility should be temporary or removed in the first implementation.
- Confirm whether `runtime.surface` should expose current internal names such as `implementation_skill` and `review_skill`, or whether `A2O#270` should rename them in the same user-facing schema before implementation.
- Confirm whether `a3:follow-up-child` remains acceptable as a default internal label or should move behind an A2O-facing alias as part of diagnostics cleanup.
