# Project Package Schema Reference

This document is the detailed `project.yaml` reference. For setup intent and responsibility boundaries, read [20-project-package.md](20-project-package.md) first.

Use this document when adding or changing settings. First understand why the package needs a setting, then use this reference to confirm YAML shape, default responsibility boundaries, and supported placeholders.

## Policy

The canonical project package config file is `project.yaml`.

Runtime responsibilities live in `project.yaml` under explicit runtime sections. The public package has one configuration file so package authors do not need to split responsibility between separate project and runtime manifests.

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
  agent_poll_interval: 1s
  agent_control_plane_connect_timeout: 5s
  agent_control_plane_request_timeout: 30s
  agent_control_plane_retry_count: 2
  agent_control_plane_retry_delay: 1s
  review_gate:
    child: false
    single: false
    skip_labels: []
    require_labels: []
  decomposition:
    investigate:
      command: [app/project-package/commands/investigate.sh]
    author:
      command: [app/project-package/commands/author-proposal.sh]
    review:
      commands:
        - [app/project-package/commands/review-proposal-architecture.sh]
        - [app/project-package/commands/review-proposal-planning.sh]
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
      policy: ff_only
      target_ref: refs/heads/main
```

## Package

`package.name` is the stable package identity. It should be filesystem and branch-ref safe.

## Kanban

`kanban.project` is the board/project name. A2O provisions required lanes and internal labels through `a2o kanban up`.

`kanban.selection.status` selects runnable tasks. The default is `To do`.

## Runtime

`runtime.agent_attempts` and `runtime.agent_poll_interval` control the outer host-agent loop.

`runtime.agent_control_plane_connect_timeout`, `runtime.agent_control_plane_request_timeout`, `runtime.agent_control_plane_retry_count`, and `runtime.agent_control_plane_retry_delay` control the host agent's HTTP client when it talks to the local agent server. Use these when TCP connect timeouts or transient control-plane failures need project-specific tuning.

`runtime.review_gate.child` and `runtime.review_gate.single` are optional booleans. They default to `false`. When enabled for a task kind, successful implementation transitions to `review` before verification. Review approval continues to verification; review findings can require rework and return the task to implementation.

`runtime.review_gate.skip_labels` and `runtime.review_gate.require_labels` are optional arrays of kanban label names. `require_labels` forces the review gate on for matching tasks even when the task-kind default is `false`; `skip_labels` forces it off for matching tasks even when the task-kind default is `true`. If both lists match the same task, `skip_labels` takes precedence.

Project-specific human labels can be declared in `kanban.labels`. A2O-owned trigger and internal coordination labels are not user-authored.

For multi-repo parent tasks, add every affected repo label to the kanban task. Do not create aggregate labels that mean "all repos" or "both repos"; aggregate labels do not scale beyond two repositories and do not map directly to repo slots.

## Repos

Each repo slot defines:

- local path
- role
- kanban label

Repo slots are stable aliases used in runtime state and agent job payloads.

## Agent

`agent.required_bins` lists commands that must exist where `a2o-agent` runs.

`agent.workspace_root` is disposable runtime output. It should normally live under `.work/a2o/`.

## Runtime Decomposition

`runtime.decomposition.investigate.command` is the project-owned command for `trigger:investigate` ticket decomposition. `runtime.decomposition.author.command` is the project-owned command that turns investigation evidence into a normalized child-ticket proposal. They are optional unless the project wants A2O to run the matching decomposition pipeline step.

Each command must be a non-empty array of non-empty strings:

```yaml
runtime:
  decomposition:
    investigate:
      command:
        - app/project-package/commands/investigate.sh
        - "--format"
        - json
    author:
      command:
        - app/project-package/commands/author-proposal.sh
        - "--format"
        - json
    review:
      commands:
        - [app/project-package/commands/review-proposal-architecture.sh]
        - [app/project-package/commands/review-proposal-planning.sh]
```

A2O runs decomposition commands in an isolated disposable decomposition workspace. The investigation command receives public `A2O_*` paths:

- `A2O_DECOMPOSITION_REQUEST_PATH`
- `A2O_DECOMPOSITION_RESULT_PATH`
- `A2O_WORKSPACE_ROOT`

The request JSON includes the source task `title`, `description`, labels, priority, parent/child/blocker refs, isolated repo `slot_paths`, `source_task`, and rerun context fields `previous_evidence_path` and `previous_evidence_summary` when prior investigation evidence exists. A2O requires non-empty source task title and description before running investigation.

The command writes one JSON object to `A2O_DECOMPOSITION_RESULT_PATH`. The MVP requires `summary` as a non-empty string. Non-zero exit, missing JSON, invalid JSON, or missing `summary` blocks the decomposition run with evidence.

To run investigation:

```bash
a2o runtime decomposition investigate A2O#123 --repo-source repo_alpha=/path/to/repo
```

The author command receives:

- `A2O_DECOMPOSITION_AUTHOR_REQUEST_PATH`
- `A2O_DECOMPOSITION_AUTHOR_RESULT_PATH`
- `A2O_WORKSPACE_ROOT`

The author command writes one proposal JSON object to `A2O_DECOMPOSITION_AUTHOR_RESULT_PATH`. A2O normalizes the draft, derives `proposal_fingerprint` and per-child `child_key` values, and stores proposal evidence without creating Kanban child tickets. The proposal must include at least one child draft. Each child draft requires `title`, `body`, `acceptance_criteria`, `labels`, `depends_on`, `boundary`, and `rationale`. `boundary` must be stable across reruns because A2O derives the child idempotency key from it. `unresolved_questions` must be an array.

To run the proposal step after investigation evidence exists:

```bash
a2o runtime decomposition propose A2O#123
```

By default A2O reads investigation evidence from `decomposition-evidence/<task>/investigation.json` under the storage directory. Use `--investigation-evidence-path` to provide another evidence file. When the task is backed by an external Kanban ticket, A2O posts the proposal summary back to that source ticket.

Proposal review commands are run sequentially. Each command receives:

- `A2O_DECOMPOSITION_REVIEW_REQUEST_PATH`
- `A2O_DECOMPOSITION_REVIEW_RESULT_PATH`
- `A2O_WORKSPACE_ROOT`

Each review result should be a JSON object with `summary` and `findings`. Findings use `severity` values `critical`, `major`, `minor`, or `info`; any `critical` finding blocks the proposal and records evidence. A clean review marks the proposal `eligible` for the next configured gate but does not create child tickets.

```bash
a2o runtime decomposition review A2O#123
a2o runtime decomposition status A2O#123
```

Child ticket creation is behind an explicit gate and requires a Kanban command boundary:

```bash
a2o runtime decomposition create-children A2O#123 --gate
```

The command refuses to create children without `--gate`, records `gate_closed` evidence without changing an eligible proposal to `blocked`, requires an eligible proposal review for the same proposal fingerprint, reuses existing children by child key, and only then applies `trigger:auto-implement`.

Trial cleanup is dry-run by default:

```bash
a2o runtime decomposition cleanup A2O#123 --dry-run
a2o runtime decomposition cleanup A2O#123 --apply
```

Cleanup reports the local evidence and disposable workspace paths for the task slug, including proposal fingerprint and child refs discovered from evidence. `--apply` removes only `decomposition-evidence/<task>` and `decomposition-workspaces/<task>` for the selected task. Kanban tickets and comments are not deleted by this command.

The host launcher wrapper reads storage, project config, Kanban, repo label, and default repo source settings from the bootstrapped runtime package. Use `--project-config project-test.yaml` when the package contains a non-default config file. The lower-level runtime-container commands remain available for diagnostics, but user-facing operation should prefer the `a2o runtime decomposition ...` wrapper.

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

Project commands should treat the worker request JSON and `A2O_*` worker environment variables as the stable contract. Do not read private `.a2o/.a3` metadata files or generated `launcher.json` files from package scripts.
Implementation, review, verification, and remediation jobs all expose `A2O_WORKER_REQUEST_PATH`. Verification and remediation request JSON includes `command_intent`, `slot_paths`, `scope_snapshot`, and `phase_runtime`; use those fields to decide which repo slots and policies to apply.
For slot-local remediation, the command may run with a repo slot as the current directory, while the request still describes the full prepared workspace.

Verification and remediation commands may also use the same `default` / `variants` shape used by merge settings. Use this only when command policy depends on `task_kind`, `repo_scope`, or phase:

```yaml
runtime:
  phases:
    verification:
      commands:
        default:
          - app/project-package/commands/verify-all.sh
        variants:
          task_kind:
            parent:
              phase:
                verification:
                  - app/project-package/commands/verify-parent.sh
    remediation:
      commands:
        default:
          - app/project-package/commands/format-all.sh
        variants:
          task_kind:
            child:
              repo_scope:
                repo_beta:
                  phase:
                    verification:
                      - app/project-package/commands/format-repo-beta.sh
```

The simple list form remains the recommended default. Use variants when the package would otherwise hide task-kind or repo-slot policy in helper code.
`default` may be specified at the top level, under a `task_kind`, or under a `repo_scope`; the most specific matching value wins.

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

`project.yaml` is the normal production profile. Focused test profiles may use a separate file such as `project-test.yaml`, but they must be selected explicitly with `a2o project validate --config project-test.yaml` or `a2o runtime run-once --project-config project-test.yaml`.

## Current Contract

1. `project.yaml` schema version `1` is the public config contract.
2. Runtime bridge data is derived from `runtime.phases`.
3. Reference product packages use only `project.yaml`.
4. Package loading rejects unsupported split config files.
5. Schema, docs, and diagnostics use A2O-facing names.
