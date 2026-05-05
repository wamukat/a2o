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
docs:
  repoSlot: app
  root: docs
  index: docs/README.md
  categories:
    architecture:
      path: docs/architecture
      index: docs/architecture/README.md
  languages:
    primary: en
  impactPolicy:
    defaultSeverity: warning
    mirrorPolicy: require_canonical_warn_mirror
  authorities:
    openapi:
      source: openapi.yaml
      docs:
        - docs/api.md
agent:
  workspace_root: .work/a2o/agent/workspaces
  required_bins:
    - git
    - node
    - npm
    - your-ai-worker
publish:
  commit_preflight:
    native_git_hooks: bypass
    commands:
      - ./project-package/commands/publish-preflight.sh
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

`runtime.delivery` is optional. When omitted, A2O uses `local_merge` and the merge phase updates the configured local target ref.

Use `runtime.delivery.mode: remote_branch` when A2O should publish completed parent or single-task work to a provider-neutral remote branch instead of directly updating the live branch locally:

```yaml
runtime:
  delivery:
    mode: remote_branch
    remote: origin
    base_branch: main
    branch_prefix: a2o/
    push: true
    sync:
      before_start: fetch
      before_resume: fetch
      before_push: fetch
      integrate_base: none
      conflict_policy: stop
    after_push:
      command: [after-push-remote-branch]
```

For `remote_branch`, `remote` and `base_branch` are required. `branch_prefix` defaults to `a2o/`. A2O derives the final branch from the task ref, for example `refs/heads/a2o/A2O-286`, fetches the remote, merges into that task branch, and pushes it to the configured remote. If the remote task branch already exists, A2O bootstraps from that remote branch so reruns update the same delivery branch. A2O refuses non-fast-forward pushes.

`after_push.command` is optional. It runs after a successful push with the repo source root as the current working directory. Prefer a command available on `PATH`, an absolute path, or a path relative to each repo source root; do not assume paths are relative to the project package directory. A2O writes a JSON event to stdin containing `task_ref`, `external_task_id`, `remote_issue`, `base_branch`, `remote`, `branch`, `pushed_ref`, `commit`, `slot`, and merge refs. Hook failure fails the merge phase and records the hook log in merge diagnostics. A2O core does not create provider pull requests, merge requests, merge commits, or close remote issues; use the hook for project-specific provider automation.

Project-specific human labels can be declared in `kanban.labels`. A2O-owned trigger and internal coordination labels are not user-authored.

For multi-repo parent tasks, add every affected repo label to the kanban task. Do not create aggregate labels that mean "all repos" or "both repos"; aggregate labels do not scale beyond two repositories and do not map directly to repo slots.

## Repos

Each repo slot defines:

- local path
- role
- kanban label

Repo slots are stable aliases used in runtime state and agent job payloads.

## Docs

`docs` is optional. It declares the documentation surface that A2O may inspect or update when a task has documentation impact. In a single-repo package, `docs.repoSlot` may be omitted and A2O treats docs paths as belonging to that repo slot. In multi-repo packages, or when docs live in a dedicated repository, declare the repository under `repos` and set `docs.repoSlot` to the matching slot.

```yaml
docs:
  repoSlot: docs
  root: docs
  index: docs/README.md
  categories:
    architecture:
      path: docs/architecture
      index: docs/architecture/README.md
    shared_specs:
      path: docs/shared-specs
  languages:
    primary: en
    secondary: [ja]
  policy:
    missingRoot: create
  impactPolicy:
    defaultSeverity: warning
    mirrorPolicy: require_canonical_warn_mirror
  authorities:
    openapi:
      source: openapi.yaml
      docs:
        - docs/api.md
```

`docs.root`, `docs.index`, category paths, authority sources, and authority docs are repo-slot-relative paths. A2O rejects absolute paths, `..` escapes, and existing symlinks that resolve outside the selected repo slot. `docs.repoSlot` must match a declared `repos` entry. Category and authority IDs must be non-empty machine-readable keys such as `architecture`, `shared_specs`, or `openapi`.

Multi-repo packages can declare multiple documentation surfaces. A surface is a named docs area with its own `repoSlot`, root, categories, and optional `role`. Use `role: integration` for cross-repo architecture or interface docs that should be visible even when a task edits only one product repo.

```yaml
docs:
  surfaces:
    app:
      repoSlot: app
      root: docs
      categories:
        features:
          path: docs/features
    lib:
      repoSlot: lib
      root: docs
      categories:
        shared_specs:
          path: docs/shared-specs
    integrated:
      repoSlot: docs
      root: docs
      role: integration
      categories:
        interfaces:
          path: docs/interfaces
  authorities:
    greeting_schema:
      repoSlot: lib
      source: docs/shared-specs/greeting-format.md
      docs:
        - surface: lib
          path: docs/shared-specs/greeting-format.md
        - surface: integrated
          path: docs/interfaces/greeting-api.md
```

When `docs.surfaces` is present, each surface path is relative to that surface's repo slot. Authority sources can also declare `repoSlot`; authority `docs` entries may use `{surface, path}` so a source-of-truth artifact in one repo can point to generated or mirrored docs in another surface. Existing single-surface `docs.repoSlot` configs remain valid.

`docs.impactPolicy.mirrorPolicy` controls mirror debt handling for `docs.languages.secondary`: `require_all` means every declared language should be updated together, `require_canonical_warn_mirror` records mirror debt for missing secondary docs, and `canonical_only` suppresses mirror debt.

Authority sources represent source-of-truth artifacts such as OpenAPI, DB migrations, generated schema files, or existing shared specifications. A non-generated authority source must exist when the repo slot checkout is available. Use `generated: true` only when project policy intentionally treats the source as generated outside the current checkout.

### Docs-impact workflow

When `docs` is configured, A2O includes `docs_context` in implementation, review, and parent-review worker requests. The context gives workers the configured categories, surfaces, candidate docs, authority sources, language policy, expected docs actions, and traceability refs. Candidate docs include `surface_id`, `repo_slot`, optional `role`, and `expected_action`, so workers can distinguish repo-local docs from integration docs. Workers still decide the actual impact per task and report it through the `docs_impact` evidence object.

Implementation results can include:

```json
{
  "docs_impact": {
    "disposition": "yes",
    "categories": ["shared_specs", "interfaces"],
    "updated_docs": [
      "docs/shared-specs/greeting-format.md",
      "docs/interfaces/greeting-api.md"
    ],
    "updated_authorities": ["greeting_api"],
    "skipped_docs": [
      {
        "path": "docs/ja/interfaces/greeting-api.md",
        "reason": "mirror follow-up"
      }
    ],
    "matched_rules": ["interface_changed"],
    "review_disposition": "accepted",
    "traceability": {
      "related_requirements": ["A2O#394"],
      "source_issues": ["wamukat/a2o#16"],
      "related_tickets": ["A2O#391", "A2O#393"]
    }
  }
}
```

Review phases check the same evidence. For `disposition: yes` or `maybe`, review must set `review_disposition` to `accepted`, `warned`, `blocked`, or `follow_up`. A blocked child review returns to implementation; a parent-review follow-up must create or link a follow-up child so docs debt is not hidden by a clean task result.

Kanban comments contain only a short docs-impact summary. Runtime state such as current lane, run status, review disposition, and merge status remains in run evidence and task comments. Do not copy those lifecycle fields into docs front matter.

Existing projects can omit `docs` and continue to run. To migrate incrementally, add `docs.root`, one category, and one managed index block first, then add authorities and language policy once the team agrees on the source of truth. A2O refuses unsafe docs paths with explicit validation errors, so fix package validation before enabling runtime processing.

### Refactoring assessment workflow

Implementation, review, parent-review, and decomposition author outputs may include optional `refactoring_assessment`. A2O defines the schema and records the assessment in evidence and concise Kanban comments. The project package defines the actual policy through prompts, skills, and docs: what counts as debt, which module boundaries matter, when debt can be included in the current child, and when it must become a separate or follow-up child.

```json
{
  "refactoring_assessment": {
    "disposition": "defer_follow_up",
    "reason": "The new branch duplicates existing factory selection logic.",
    "scope": ["repo_beta/app/services/address"],
    "recommended_action": "create_follow_up_child",
    "risk": "medium",
    "evidence": ["Factory A and Factory B already share the same responsibility."]
  }
}
```

`disposition` must be one of `none`, `include_child`, `defer_follow_up`, `blocked_by_design_debt`, or `needs_clarification`. `recommended_action`, when present or required by a non-`none` disposition, must be one of `none`, `document_only`, `include_in_current_child`, `create_refactoring_child`, `create_follow_up_child`, `request_clarification`, or `block_until_decision`.

For decomposition, `include_child` means the proposal should include a normal child draft for the refactoring work. `defer_follow_up` records debt on the source-ticket summary and generated implementation parent but does not block child creation. `blocked_by_design_debt` and `needs_clarification` are distinct from ordinary technical blocked failures; use them only when project policy says safe implementation requires a design decision or requester input.

## Agent

`agent.required_bins` lists project-owned commands that must exist where `a2o-agent` runs, such as the product toolchain and the configured AI worker executable. If it is omitted, A2O checks only its own minimum host-agent prerequisite, `git`; it does not assume product-specific tools such as Node, npm, Maven, or Gradle.

Toolchain-specific environment variables are also package-owned. A2O exposes generic workspace paths such as `A2O_WORKSPACE_ROOT` and `AUTOMATION_ISSUE_WORKSPACE`, but it does not inject Maven, npm, Gradle, or language-specific cache variables. Put those values in the phase executor `env` block or in package command scripts.

`agent.workspace_root` is disposable runtime output. It should normally live under `.work/a2o/`.

## Publish

`publish.commit_preflight` defines A2O-managed checks that run when A2O creates an agent-owned publish commit.

`publish.commit_preflight.commands` is an optional list of project-owned shell commands. A2O runs each command from the repo slot checkout root after staging the publish changes and before creating the publish commit. Commands must be deterministic in the agent workspace and must not mutate files; use phase remediation commands for formatting or code generation.

If any command exits non-zero, A2O blocks the publish commit and records the failing command and output in the workspace publish evidence. The slot branch is rolled back to the pre-publish head.

`publish.commit_preflight.native_git_hooks` controls whether A2O lets repository Git commit hooks run for that publish commit.

- `bypass` is the default and preserves the historical behavior. A2O commits with `--no-verify`, so repository `pre-commit` hooks do not block the mechanical publish commit.
- `run` is opt-in. A2O omits `--no-verify`, so configured Git commit hooks such as `pre-commit` can block the publish commit.

Use `run` only when the hook is deterministic in the agent workspace and its required tools are declared in `agent.required_bins`. A failing hook blocks the phase publish and leaves the task needing remediation or operator attention.

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

The author command writes one proposal JSON object to `A2O_DECOMPOSITION_AUTHOR_RESULT_PATH`. A2O normalizes the draft, derives `proposal_fingerprint` and per-child `child_key` values, and stores proposal evidence without creating Kanban child tickets. `outcome` is optional and defaults to `draft_children` for compatibility.

`draft_children` proposals must include at least one child draft. They may include optional `parent.title` and `parent.body`; those values are used only when A2O first creates the generated implementation parent, while A2O always keeps its own source-ticket and proposal-fingerprint metadata. Existing generated parent title/body are not overwritten on rerun. Each child draft requires `title`, `body`, `acceptance_criteria`, `labels`, `depends_on`, `boundary`, and `rationale`. `boundary` must be stable across reruns because A2O derives the child idempotency key from it. `depends_on` should list other child `boundary` values from the same proposal when one generated child must be blocked by another; A2O also accepts generated `child_key` values for rerun compatibility. `unresolved_questions` must be an array.

Use `parent.title` and `parent.body` when the generated implementation parent should carry a project-specific plan instead of the default A2O title/body. The author command returns them in the proposal JSON:

```json
{
  "outcome": "draft_children",
  "parent": {
    "title": "Implementation plan for address suggestions",
    "body": "## Feature overview\nAdd address suggestion support.\n\n## Design notes\nKeep provider integration behind the existing address service boundary.\n\n## Overall acceptance criteria\n- All generated child tickets are Done.\n- The parent verification confirms the end-to-end address suggestion flow."
  },
  "children": [
    {
      "title": "Add address provider contract",
      "body": "Define the provider-facing contract.",
      "acceptance_criteria": ["Contract is documented", "Tests cover fallback behavior"],
      "labels": ["repo:app"],
      "depends_on": [],
      "boundary": "address-provider-contract",
      "rationale": "This isolates the shared service contract from UI work."
    },
    {
      "title": "Wire address suggestions into the UI",
      "body": "Call the address provider contract from the UI flow.",
      "acceptance_criteria": ["UI displays suggestions", "Fallback behavior is covered"],
      "labels": ["repo:web"],
      "depends_on": ["address-provider-contract"],
      "boundary": "address-suggestion-ui",
      "rationale": "UI work should start after the shared provider contract exists."
    }
  ],
  "unresolved_questions": []
}
```

Project prompts should tell the proposal author what belongs in `parent.body`, such as a feature overview, design notes, child-ticket summary, and cross-child acceptance criteria. Do not put imported remote issue metadata in `parent.body`; A2O preserves source provenance through relations, evidence, and external references where supported.

`no_action` proposals use `children: []` plus a non-empty `reason` when the requested behavior is already satisfied and no implementation tickets should be created. `needs_clarification` proposals use `children: []`, a non-empty `reason`, and at least one `questions` entry; A2O posts the question summary and routes the source ticket through the existing clarification status/label behavior.

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

The command refuses to create children without `--gate`, records `gate_closed` evidence without changing an eligible proposal to `blocked`, requires an eligible proposal review for the same proposal fingerprint, creates or reuses a generated implementation parent traceable to the requirement source ticket, and reuses existing children by child key under that generated parent. In Kanban-first draft mode, created children and the generated parent are placed in `Backlog`; created or reused children remain draft planning artifacts. A2O labels children with `a2o:draft-child` and does not apply `trigger:auto-implement` or `trigger:auto-parent`. A2O converts child `depends_on` entries into Kanban `blocked` relations between generated child tickets, resolving dependencies by matching either proposal `boundary` values or generated `child_key` values. A child enters implementation scheduling only after an operator accepts it by adding `trigger:auto-implement` and moves it from `Backlog` to the runnable `To do` lane; parent automation applies to the generated parent, not the original requirement source ticket.

Trial cleanup is dry-run by default:

```bash
a2o runtime decomposition cleanup A2O#123 --dry-run
a2o runtime decomposition cleanup A2O#123 --apply
```

Cleanup reports the local evidence and disposable workspace paths for the task slug, including proposal fingerprint and child refs discovered from evidence. `--apply` removes only `decomposition-evidence/<task>` and `decomposition-workspaces/<task>` for the selected task. Kanban tickets and comments are not deleted by this command.

The host launcher wrapper reads storage, project config, Kanban, repo label, and default repo source settings from the bootstrapped runtime package. Use `--project-config project-test.yaml` when the package contains a non-default config file. The lower-level runtime-container commands remain available for diagnostics, but user-facing operation should prefer the `a2o runtime decomposition ...` wrapper.

## Runtime Prompts

`runtime.prompts` is optional. When omitted, A2O keeps the existing phase skill behavior. For migration from existing phase skills, see [Runtime Prompt Migration](#runtime-prompt-migration).

The section defines provider-neutral project prompt inputs. These files are additive project guidance; they do not override A2O core safety rules, worker result schemas, workspace boundaries, or runtime control rules.

```yaml
runtime:
  prompts:
    system:
      file: prompts/system.md
    phases:
      implementation:
        prompt: prompts/implementation.md
        skills:
          - skills/testing-policy.md
      implementation_rework:
        prompt: prompts/implementation-rework.md
      review:
        prompt: prompts/review.md
      parent_review:
        prompt: prompts/parent-review.md
      decomposition:
        prompt: prompts/decomposition.md
        childDraftTemplate: prompts/decomposition-child-template.md
    repoSlots:
      app:
        phases:
          review:
            skills:
              - skills/app-review.md
```

All paths are package-relative non-empty strings. Prompt phase names are limited to A2O-recognized phase profiles. `phases.<phase>.skills` preserves the declared order and must not list the same skill file more than once. `implementation_rework` is optional and falls back to `implementation` when no rework-specific prompt profile is configured. `repoSlots.<slot>.phases` is an additive layer on top of the project phase defaults, and `<slot>` must match a `repos` entry. Phase prompts and skills are composed before repo-slot prompts and skills. Diagnostics and evidence identify repo-slot layers as `repo_slot_phase_prompt`, `repo_slot_phase_skill`, or `repo_slot_decomposition_child_draft_template`.

For tasks that span multiple repositories, A2O composes repo-slot addons for each slot in the task `repo_slots` / `edit_scope`, in that order. A multi-repo implementation touching `app` and `lib` therefore receives the project-wide phase prompt first, then `repoSlots.app` phase addons, then `repoSlots.lib` phase addons, before ticket-specific instructions. Diagnostics expose `repo_slots` as the ordered list; the legacy `repo_scope` field is kept for compatibility and the singular `repo_slot` field is populated only for single-slot tasks. If the combined instructions would be too broad or conflicting, split the work into repo-slot child tasks.

Composition order is fixed and additive:

```text
A2O core worker contract
  > runtime.prompts.system
  > runtime.prompts.phases.<profile>.prompt
  > runtime.prompts.phases.<profile>.skills
  > runtime.prompts.repoSlots.<slot>.phases.<profile> addons for each scoped slot
  > ticket-specific instruction and task packet
```

Project prompts can define language, tone, local conventions, review stance, decomposition policy, and reusable phase guidance. They cannot disable required result schemas, workspace boundaries, branch/publish safety, Kanban gates, review requirements, or runtime state transitions. If a project prompt conflicts with an A2O runtime rule, the runtime rule wins.

Typical prompt files are short Markdown files:

```markdown
<!-- prompts/system.md -->
Respond in Japanese. Keep user-facing comments concise. Preserve existing project conventions and avoid unrelated refactors.

<!-- prompts/implementation.md -->
Implement the smallest coherent change for the ticket. Run focused tests first, then broader checks when shared behavior changes. Report changed files and verification.

<!-- prompts/review.md -->
Review for regressions, incomplete acceptance coverage, missing tests, and unsafe compatibility changes. Findings must include file and line references.

<!-- prompts/parent-review.md -->
Judge whether child outputs integrate cleanly. Identify follow-up child work only when it is required before parent completion.

<!-- prompts/decomposition.md -->
Split broad requirements into draft child tickets with clear ownership, dependencies, non-goals, acceptance criteria, and verification method.
```

Skills are longer reusable Markdown guidance referenced from a phase. Use prompts for phase stance and instruction layering; use skills for detailed procedures such as testing policy, API compatibility rules, UI review checklist, or Kanban decomposition templates. `childDraftTemplate` is decomposition-specific guidance for the expected child ticket shape. It is passed to the proposal author request, while durable evidence stores only safe prompt metadata.

Inspect prompt composition before running a worker with:

```bash
a2o prompt preview --phase review A2O#123
a2o prompt preview --phase decomposition --repo-slot app A2O#123
a2o prompt preview --phase decomposition --repo-slot app --repo-slot lib A2O#123
```

The preview prints each non-mutating layer, including A2O core instruction, project system prompt, phase prompt, phase skills, repo-slot addons, ticket phase instruction, task/runtime data, and the final composed instruction when those layers apply to the selected phase. Repeat `--repo-slot` in the same order as the task `repo_slots` / `edit_scope` to preview multi-repo composition. Use `--task-kind parent` to preview `parent_review`, and `--prior-review-feedback` to preview `implementation_rework`.

Validate prompt configuration without running workers or changing Kanban state with:

```bash
a2o doctor prompts
```

The prompt doctor reports missing files, invalid paths, unsupported prompt phases, duplicate skill entries, invalid repo-slot addons, fallback-visible prompt profiles, and invalid `childDraftTemplate` placement with package path and phase context.

A copyable baseline is available at `samples/prompt-packs/ja-conservative/`. It demonstrates a Japanese system prompt, phase prompts for implementation, implementation rework, review, parent review, and decomposition, reusable phase skills, a decomposition child draft template, and a minimal `runtime.prompts` config snippet.

## Prompt Authoring Boundaries

Use the narrowest durable surface that matches the instruction:

- Project system prompt: language, tone, stable project-wide rules, compatibility posture, and general policy that should apply to every phase.
- Phase prompt: short behavior guidance that changes by phase, such as implementation scope, implementation rework stance, review disposition, parent-review integration policy, or decomposition strategy.
- Phase skill: longer reusable procedures such as testing policy, technology-specific operating notes, migration guides, domain checklists, review rubrics, and decomposition rules.
- Ticket-specific instruction: task-local acceptance criteria, one-off constraints, temporary exceptions, human decisions, priority, and evidence required for that ticket.

Keep project prompts and skills durable. If an instruction applies to one ticket only, put it in the ticket. If it applies to one phase across many tickets, put it in that phase prompt or a phase skill. If it applies across all phases and is unlikely to change per task, put it in the system prompt.

Common anti-patterns:

- Putting one-off ticket requirements in `prompts/system.md`, which makes future unrelated tasks inherit stale constraints.
- Duplicating the same long checklist in every phase prompt instead of referencing one phase skill.
- Putting schema override, workspace escape, branch bypass, Kanban mutation, or review-skip instructions in project prompt files. A2O core contracts are not overridable.
- Putting product decisions that require human approval into reusable skills. Keep those decisions on the ticket or in explicit project documentation.
- Using ticket comments for stable project policy that should be versioned with the project package.

Precedence remains additive: A2O core worker contract and phase skill come first, then `runtime.prompts.system`, phase prompt, phase skills, repo-slot addons, and finally ticket-specific instruction. `implementation_rework` falls back to `implementation` when no rework-specific prompt profile is configured; `parent_review` is selected for parent review runs. For existing project packages, see [Runtime Prompt Migration](#runtime-prompt-migration). For a copyable baseline, see `samples/prompt-packs/ja-conservative/`.

## Runtime Prompt Migration

Existing project packages do not need to migrate before adopting a new A2O version. The released phase execution surface remains supported:

- `runtime.phases.implementation.skill`
- `runtime.phases.review.skill`
- `runtime.phases.parent_review.skill`, when the project uses parent review
- phase executor, verification, remediation, and merge commands under `runtime.phases`
- decomposition command configuration under `runtime.decomposition`

The new `runtime.prompts` surface is additive guidance. It does not replace the phase skill or executor contract. Keep the current phase skills in place while moving project-specific guidance into prompt files, then simplify the old skill files only after the project has validated the new prompt layering.

Before migration, a project usually keeps most guidance inside phase skills:

```yaml
runtime:
  phases:
    implementation:
      skill: skills/implementation.md
      executor:
        command: [project-package/commands/implementation.sh]
    review:
      skill: skills/review.md
      executor:
        command: [project-package/commands/review.sh]
    parent_review:
      skill: skills/parent-review.md
      executor:
        command: [project-package/commands/parent-review.sh]
  decomposition:
    author:
      command: [project-package/commands/decompose.sh]
```

After migration, keep the phase skills as the runtime worker contract and add project prompt layers for project policy, phase stance, reusable checklists, rework behavior, and decomposition ticket shape:

```yaml
runtime:
  prompts:
    system:
      file: prompts/system.md
    phases:
      implementation:
        prompt: prompts/implementation.md
        skills:
          - skills/testing-policy.md
      implementation_rework:
        prompt: prompts/implementation-rework.md
      review:
        prompt: prompts/review.md
        skills:
          - skills/review-checklist.md
      parent_review:
        prompt: prompts/parent-review.md
      decomposition:
        prompt: prompts/decomposition.md
        childDraftTemplate: prompts/decomposition-child-template.md
  phases:
    implementation:
      skill: skills/implementation.md
      executor:
        command: [project-package/commands/implementation.sh]
    review:
      skill: skills/review.md
      executor:
        command: [project-package/commands/review.sh]
    parent_review:
      skill: skills/parent-review.md
      executor:
        command: [project-package/commands/parent-review.sh]
  decomposition:
    author:
      command: [project-package/commands/decompose.sh]
```

Use this split when moving existing content:

- Project system prompt: language, tone, product-wide conventions, compatibility posture, and repository ownership rules.
- Phase prompt: the goal and decision policy for one phase, such as implementation scope, rework handling, review disposition, parent integration review, or decomposition strategy.
- Phase skill files under `runtime.prompts.phases.<phase>.skills`: longer reusable procedures, checklists, testing policy, API compatibility rules, and review heuristics.
- Ticket-specific instructions: acceptance criteria, requested behavior, priority, constraints, and evidence required for the specific ticket.

Precedence is fixed. When `runtime.phases.<phase>.skill` is configured, that legacy phase skill is emitted first as the `a2o_core_instruction` layer and remains authoritative for worker result schemas, process boundaries, and required outputs. `runtime.prompts` layers are appended after that contract and before ticket-specific instructions. If both old phase skills and new prompt config are present, the project prompt may add context but cannot override A2O runtime rules, workspace boundaries, Kanban gates, or result schemas.

Projects that have fully moved a phase to `runtime.prompts.phases.<phase>` may omit `runtime.phases.<phase>.skill` for that phase. In that prompts-only mode, A2O does not emit an `a2o_core_instruction` layer for the omitted skill; the project system prompt, phase prompt, phase skill files, repo-slot addons, and ticket-specific instruction form the project prompt stack. The corresponding prompt phase must contain at least one prompt or skill file. A system prompt alone does not make a phase prompts-backed.

`implementation_rework` is a prompt profile, not a separate scheduler phase. It is selected for implementation requests that include prior review feedback, and it falls back to `implementation` when omitted. `phase_runtime.prior_review_feedback` includes the previous review run `summary`, `observed_state`, and `failing_command`, plus the structured review result as a `review_disposition` object when the review worker returned one. Rework workers can read `prior_review_feedback.review_disposition.kind`, `description`, `finding_key`, and `slot_scopes` instead of parsing free-form Kanban comments. These values are not copied to the top level of `prior_review_feedback`; the nested `review_disposition` object is the source of truth. `parent_review` follows the same prompt layering as other review profiles. `decomposition` uses the decomposition prompt plus optional `childDraftTemplate`; the template is allowed only for decomposition and should describe the expected draft child ticket format.

A2O reports invalid prompt migration through `a2o project validate` and `a2o project lint` diagnostics. Typical failures include missing prompt or skill files, paths outside the package root, non-file paths, unsupported prompt phase names, duplicate skill files in one phase layer, unknown `repoSlots` keys, duplicate repo-slot skill additions, and `childDraftTemplate` outside `decomposition`. Validation coverage exists for both old-style packages without `runtime.prompts` and new-style packages with project prompt configuration.

This is a coexistence policy, not a deprecation notice. Existing phase skills continue to work until a deliberate migration/removal plan is documented in a future release, while prompts-only phases are supported for projects that have intentionally moved their phase guidance into `runtime.prompts`.

## Runtime Phases

`runtime.phases.<phase>.skill` points to a package skill file. It may be omitted for implementation or review phases only when the matching `runtime.prompts.phases.<phase>` entry contains prompt or skill content. If neither a phase skill nor a matching prompt phase is configured, validation fails with a `runtime.phases.<phase>.skill must be provided` diagnostic.

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

### Implementation Completion Hooks

`runtime.phases.implementation.completion_hooks.commands` defines project-owned commands that run after the implementation worker reports success and before A2O accepts that implementation for review or verification. In the normal A2O-managed flow, this means the hooks run before A2O publishes the implementation attempt as the commit that the review phase will inspect.

Use completion hooks when the project needs an implementation feedback loop, for example to run formatting, generation, or a fast implementation gate and ask the implementation worker to rework the result before review. They are not a replacement for native repository Git hooks; they are project-package policy hooks that A2O runs inside the implementation phase boundary.

```yaml
runtime:
  phases:
    implementation:
      completion_hooks:
        commands:
          - name: fmt
            command: ./scripts/a2o/fmt-apply.sh
            mode: mutating
          - name: verify
            command: ./scripts/a2o/impl-verify.sh
            mode: check
            on_failure: rework
```

Each hook entry requires `name`, `command`, and `mode`.

- `mode: mutating` may change files in the current edit-target repo slot.
- `mode: check` must not change files.
- `on_failure` currently supports only `rework`; it may be omitted and defaults to `rework`.

A2O runs hooks in hook order across edit-target slots sorted by slot name. For each hook invocation, the current directory is the repo slot checkout root. Use commands that are valid from that slot root, such as slot-local scripts or commands on `PATH`. The command also receives:

- `A2O_WORKSPACE_ROOT`
- `A2O_COMPLETION_HOOK_NAME`
- `A2O_COMPLETION_HOOK_MODE`
- `A2O_COMPLETION_HOOK_SLOT`
- `A2O_COMPLETION_HOOK_SLOT_PATH`

If a hook exits non-zero, times out, mutates a `mode: check` slot, or changes a non-target slot, A2O restores the failed hook's side effects, publishes an implementation attempt ref containing the AI output plus any earlier successful mutating hook output, and returns controlled implementation feedback with `rework_required=true`. The task stays in implementation instead of advancing to review. The next implementation run receives prior feedback in `phase_runtime.prior_review_feedback`, including `completion_hook_diagnostics` when available.

Completion hooks share the agent job timeout budget. A timeout kills the hook process group and is treated as rework feedback. The first public version does not provide a per-hook timeout setting.

`runtime.phases.implementation.completion_hooks` is different from `publish.commit_preflight.commands`. Completion hooks run before the implementation is accepted and can intentionally mutate files or send feedback to the implementation worker. `publish.commit_preflight.commands` runs later, after publish changes have been staged and immediately before A2O creates the publish commit; it must be check-only and is a final publish safety gate.

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

### Metrics Collection

`runtime.phases.metrics.commands` is optional. When present, A2O runs these commands only after verification succeeds.

```yaml
runtime:
  phases:
    metrics:
      commands:
        - app/project-package/commands/collect-metrics.sh
```

The command is a project-owned reporting hook. It receives the normal worker request environment and `command_intent=metrics_collection`. It must print a JSON object to stdout. The object may contain:

```json
{
  "code_changes": { "lines_added": 10, "lines_deleted": 2, "files_changed": 1 },
  "tests": { "passed_count": 12, "failed_count": 0, "skipped_count": 1 },
  "coverage": { "line_percent": 84.2 },
  "timing": {},
  "cost": {},
  "custom": { "suite": "smoke" }
}
```

A2O adds `task_ref`, `parent_ref`, and `timestamp` from runtime context when storing the record. If the command output includes these metadata fields, they must match the runtime context. Each top-level section must be a JSON object. Invalid JSON, unknown top-level sections, or invalid section shapes are recorded in the verification diagnostics under `metrics_collection`; they do not hide the successful verification result.

Stored records can be exported with:

```sh
a2o runtime metrics list --format json
a2o runtime metrics list --format csv
a2o runtime metrics summary
a2o runtime metrics summary --group-by parent --format json
a2o runtime metrics trends --group-by parent --format json
```

### Observer Hooks

`runtime.observers` is optional. It declares project-owned commands that receive structured observer events. A2O emits events; the project package decides whether and how to notify external systems.

```yaml
runtime:
  observers:
    hooks:
      - event: phase.started
        command: [app/project-package/commands/notify.sh]
      - event: phase.completed
        command: [app/project-package/commands/notify.sh]
```

Observer hooks are read-only, best-effort event observers. A2O records hook failures in evidence but does not let observer results change task progress, phase outcomes, agent feedback, or workspace outputs. Commands should send notifications or audit records to external systems only. A2O runs local observer commands outside repo slot working directories where practical, and agent-materialized observer jobs request read-only repo access.

Hook `command` must be a non-empty array of non-empty strings. A2O exposes:

- `A2O_OBSERVER_EVENT_PATH`: JSON event payload path

The payload uses schema `a2o.observer/v1`:

```json
{
  "schema": "a2o.observer/v1",
  "event": "phase.completed",
  "task_ref": "A2O#283",
  "task_kind": "child",
  "status": "blocked",
  "run_ref": "run-123",
  "phase": "review",
  "terminal_outcome": "blocked",
  "parent_ref": "A2O#280",
  "summary": "worker result schema invalid",
  "diagnostics": {}
}
```

The initial emitted event set is `phase.started`, `phase.completed`, `task.blocked`, `task.needs_clarification`, `task.completed`, `task.reworked`, and `parent.follow_up_child_created`. `runtime.idle` and `runtime.error` are reserved event names for later scheduler-level observer points.

Hook execution records are stored in the latest phase execution diagnostics under `observer_hooks` with stdout, stderr, exit status, timing, command, event, and payload path.

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

### AI CLI Workspace Restrictions

When A2O uses agent-materialized workspaces, the implementation phase must work in the generated `ticket_workspace`. Configure the AI CLI executor to use that workspace as its working root and avoid editing the main working tree directly.

For Codex CLI, set `{{workspace_root}}` as the working directory and keep writes inside the workspace.

```yaml
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - codex
          - exec
          - --cd
          - "{{workspace_root}}"
          - --sandbox
          - workspace-write
          - --output-last-message
          - "{{result_path}}"
```

Use `--add-dir` only for additional write locations that are truly required. Do not add the main working tree. Do not use `--dangerously-bypass-approvals-and-sandbox` for production A2O executors, because it disables the sandbox boundary that prevents writes outside the workspace.

For GitHub Copilot CLI, keep the allowed path list focused on the `ticket_workspace`. Do not call Copilot directly from `project.yaml` unless that command still reads the A2O stdin bundle and prints the final worker result JSON to stdout. Prefer the generated command-worker wrapper and put the Copilot invocation behind it.

```sh
a2o worker scaffold --language command --output ./project-package/commands/a2o-command-worker
```

```yaml
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - ./project-package/commands/a2o-command-worker
          - --schema
          - "{{schema_path}}"
          - --result
          - "{{result_path}}"
```

Configure the delegated command so it reads the stdin bundle forwarded by `a2o-command-worker`, passes that request to Copilot, and prints the final A2O worker result JSON to stdout. Include `--add-dir "$A2O_WORKSPACE_ROOT"` in that delegated Copilot invocation and do not add the main working tree.

Copilot CLI does not currently expose a sandbox mode equivalent to Codex `workspace-write`. Avoid `--allow-all-paths`, `--allow-all`, and `--yolo` in A2O executors because they weaken path restrictions. If Copilot CLI must be prevented from writing outside the workspace, run it inside an outer isolation layer such as a container, VM, or Docker sandbox rather than relying only on CLI path permissions.

For any AI CLI, the `source alias` main working tree is input for worktree creation and merge. It is not a place for the agent to edit directly.

`--output` writes `project.yaml`. `--with-skills` also writes starter implementation, review, and parent review skills and adds a `parent_review` phase that references the generated parent skill. Kanban bootstrap data is derived from `kanban.project`, `kanban.labels`, and `repos.<slot>.label`. A2O-owned lanes and internal coordination labels are provisioned by `a2o kanban up`.

`project.yaml` is the normal production profile. Focused test profiles may use a separate file such as `project-test.yaml`, but they must be selected explicitly with `a2o project validate --config project-test.yaml` or `a2o runtime run-once --project-config project-test.yaml`.

## Current Contract

1. `project.yaml` schema version `1` is the public config contract.
2. Runtime bridge data is derived from `runtime.phases` and optional runtime extensions such as `runtime.observers`.
3. Reference product packages use only `project.yaml`.
4. Package loading rejects unsupported split config files.
5. Schema, docs, and diagnostics use A2O-facing names.
