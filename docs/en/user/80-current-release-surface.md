# A2O 0.5.69 Current Release Surface

This document describes the currently supported A2O 0.5.69 user surface and validation boundary.

Use it to confirm which features can be documented for users and what can be treated as validated at this release. For setup steps, read [10-quickstart.md](10-quickstart.md). For configuration fields, read [90-project-package-schema.md](90-project-package-schema.md).

## Supported Commands And Capabilities

- Host launcher install: `a2o host install`
- Version check: `a2o version`
- Host diagnosis: `a2o doctor`
- Project authoring and validation: `a2o project template`, `lint`, `validate`, `bootstrap`
- Worker helper commands: `a2o worker scaffold`, `a2o worker validate-result`
- Kanban service lifecycle and external Kanbalone checks: `a2o kanban up`, `doctor`, `url`
- Agent target detection and binary export: `a2o agent target`, `a2o agent install`
- Runtime container lifecycle: `a2o runtime up`, `down`
- Foreground runtime execution: `a2o runtime run-once`, `a2o runtime loop`
- Resident scheduler lifecycle: `a2o runtime resume`, `pause`, `status`
- Runtime diagnosis and recovery: `a2o runtime image-digest`, `doctor`, `watch-summary`, `logs [task-ref] --follow [--no-children]`, `describe-task <task-ref>`, `skill-feedback list`, `skill-feedback propose`, `reset-task <task-ref>`, `force-stop-task <task-ref> --dangerous`, `force-stop-run <run-ref> --dangerous`, `show-artifact <artifact-id>`
- Parent task log following keeps tracking the parent group when an active child finishes and work continues on another child or the parent task.
- `watch-summary` marks review rework/rejection as `x` while later clean review completion returns the review lane to the successful marker.
- Invalid worker results are preserved as salvage diagnostics after correction attempts are exhausted, so operators can inspect the rejected payload instead of losing it.
- Schema-invalid review worker results fail closed as `blocked`; A2O does not salvage raw `rework_required`, `review_disposition`, or merge-recovery control flags from an invalid payload.
- Implementation retries after review rework receive prior review feedback in the worker runtime context.
- Operator-applied `blocked` labels are preserved during phase completion and keep the task blocked instead of being silently removed by runtime status publication.
- Clean parent review success results are normalized to a completed review disposition when the worker omits or partially fills `review_disposition`; explicitly contradictory dispositions are still rejected. Normalization now handles frozen worker payloads without crashing the scheduler.
- Review result validation accepts optional stdin `review_disposition` payloads without requiring follow-up-only fields. `finding_key` is required only when a review finding actually creates a follow-up child or blocked outcome, so clean or completed review evidence is not rejected for irrelevant fields.
- Multi-project runtime context scopes runtime storage, host logs/workspaces, scheduler pid/log files, temp files, and branch namespaces by resolved project key. `a2o runtime resume --all-projects`, `pause --all-projects`, and `status --all-projects` operate one scheduler per registered project while preserving one active task per project.
- Upgrade diagnosis: `a2o upgrade check`
- Single-file project package config: `project.yaml`
- Publish commit preflight configuration: `publish.commit_preflight.commands` runs project-owned preflight commands before A2O-managed publish commits, and `publish.commit_preflight.native_git_hooks` controls whether those commits run native repository Git commit hooks. See [90-project-package-schema.md#publish](90-project-package-schema.md#publish).
- Investigate decomposition MVP: `runtime.decomposition.investigate.command`, `runtime.decomposition.author.command`, `a2o runtime decomposition investigate`, `propose`, `review`, `create-children`, `accept-drafts`, `status`, and `cleanup`
- `trigger:investigate` source tickets are decomposition requests and do not require `repo:*` scope labels; implementation children still require the appropriate repo labels before `trigger:auto-implement` execution.
- `a2o runtime decomposition investigate`, `propose`, and `review` execute project-owned decomposition commands through the host agent in the same host workspace boundary as implementation workers. This lets project decomposition commands call host-only agent CLIs such as Copilot while the runtime container remains the orchestrator.
- Decomposition command UX: action-level help for `a2o runtime decomposition <action> --help`, plus direct external task sync/reconciliation for one-shot decomposition commands
- Requirement decomposition source tickets are requirement artifacts. After successful decomposition they move to `Done`, and A2O creates separate generated implementation work. The source ticket is linked to the generated implementation parent with a Kanbalone `related` relation for traceability.
- If a decomposition source ticket was imported from an external issue, A2O records normalized remote metadata in child-creation evidence as `source_remote` and writes a non-tracking generated parent `externalReferences[source]` entry when Kanbalone v0.9.28 or newer is available. Older external Kanbalone endpoints keep relation/evidence traceability and record a child-creation warning instead of copying remote metadata into generated ticket text.
- Decomposition progress is visible in `a2o runtime watch-summary`: active source tickets make the scheduler summary show running, the task tree marks the source as running, and the `Decomposition` section shows the active stage.
- `a2o runtime logs <source-ref> --follow` follows decomposition source tickets by polling decomposition status and streaming live host-agent events plus action-specific investigate/propose/review command output while the decomposition command is still running. Completed action logs remain visible after the command finishes.
- Decomposition proposal `depends_on` entries are converted to Kanban `blocked` relations between generated child tickets. Dependencies resolve by proposal `boundary` values and generated `child_key` values.
- `a2o runtime decomposition accept-drafts` accepts selected draft children by adding `trigger:auto-implement`; it can optionally remove `a2o:draft-child`. By default it also adds `trigger:auto-parent` and the accepted child `repo:*` label union to the generated parent; use `--no-parent-auto` only to suppress that parent automation. The command pauses scheduler processing while mutating labels, resumes only after successful mutation when it paused the scheduler, and leaves the scheduler paused on failure for inspection.
- `a2o runtime decomposition accept-drafts <task-ref>` now fails before runtime dispatch with selector guidance when exactly one of `--child`, `--ready`, or `--all` is not provided. The user-facing error avoids leaking internal runtime `ArgumentError` stack traces.
- Gate-closed decomposition child creation reports `status=gate_closed` and `child_creation_result=not_attempted` without rendering an empty `success=` value
- Multi-repo documentation surfaces: `docs.surfaces` can declare repo-local docs and integration docs separately, while `docs.authorities` can point to source-of-truth files in a specific repo slot. Worker `docs_context` includes surface id, repo slot, role, candidate docs, and authority source metadata.
- Agent-materialized execution resolves documentation context from the actual agent source aliases and paths, so repo-local docs and cross-repo authorities are visible when the host agent owns workspace materialization.
- Project prompt composition: `runtime.prompts.repoSlots` composes repo-slot prompt and skill addons for each scoped slot in multi-repo tasks, following the task `repo_slots` / `edit_scope` order.
- Worker runtime requests and inspection output expose ordered `repo_slots` for multi-repo tasks. The legacy `repo_scope` field remains a single-scope compatibility field and may still show `both` for old variant lookup compatibility, but it is no longer the authoritative multi-repo identity.
- Prompt diagnostics and evidence expose ordered `project_prompt.repo_slots`; the legacy singular `repo_slot` field is populated only for single-slot tasks.
- Prompt preview supports multi-repo composition with repeatable or comma-separated repo slots, for example `a2o prompt preview --phase implementation --repo-slot app --repo-slot lib A2O#123` or `a2o prompt preview --phase implementation --repo-slot app,lib A2O#123`.
- Prompts-only implementation and review phases are supported: when `runtime.prompts.phases.<phase>` contains prompt or skill content, `runtime.phases.<phase>.skill` may be omitted and A2O does not emit a no-op `a2o_core_instruction` layer for that phase.
- Remote-branch delivery mode: `runtime.delivery.mode: remote_branch` publishes completed parent or single-task work to a provider-neutral task branch on a configured remote instead of directly updating the local live branch.
- Remote-branch merge/push records remote, branch, pushed ref, pushed commit, and push status in merge evidence; existing remote task branches are used as the rerun bootstrap and non-fast-forward pushes are refused.
- Optional `runtime.delivery.after_push.command` runs after a successful remote branch push with a JSON event on stdin. The hook is project-owned and is the place for provider-specific PR/MR or notification automation.
- Project runtime tuning fields for agent server connectivity: `runtime.agent_control_plane_connect_timeout`, `runtime.agent_control_plane_request_timeout`, `runtime.agent_control_plane_retry_count`, `runtime.agent_control_plane_retry_delay`
- Optional child/single review gate fields: `runtime.review_gate.child`, `runtime.review_gate.single`, `runtime.review_gate.skip_labels`, `runtime.review_gate.require_labels`
- External Kanbalone bootstrap fields: `--kanban-mode external`, `--kanban-url`, `--kanban-runtime-url`
- Runtime CLI overrides for agent server connectivity: `--agent-control-plane-connect-timeout`, `--agent-control-plane-request-timeout`, `--agent-control-plane-retries`, `--agent-control-plane-retry-delay`
- Host agent CLI and runtime profile fields for agent server connectivity: `--control-plane-connect-timeout`, `--control-plane-request-timeout`, `--control-plane-retries`, `--control-plane-retry-delay`, `control_plane_connect_timeout`, `control_plane_request_timeout`, `control_plane_retry_count`, `control_plane_retry_delay`
- Kanbalone adapter and bootstrap tooling, defaulting to Kanbalone `v0.9.33`
- Bundled Kanbalone `v0.9.33` moves tracked remote issue badges and non-tracking external reference badges from the List view ID/Title column into the Tags column, keeps normal tags before external badges, and improves two-line tag readability.
- Agent HTTP worker gateway, including claimed-job heartbeats
- Agent-materialized workspace mode
- Reference product packages for TypeScript, Go, Python, and multi-repo task templates
- GHCR runtime image tags: `latest`, `0.5.69`, and `sha-*`
- Tag releases also publish `latest`, so the released version tag and `latest` are expected to point to the same runtime image after release publication finishes.
- Local release gate: full RSpec suite, release package doctor, local RC host smoke, and real-task local RC smoke for runtime execution / worker launcher / scheduler / Kanban / env generation changes
- Developer feedback loop: `tools/dev/test-core.sh` supports deterministic Ruby example sharding with `A2O_TEST_RUBY_SHARDS`; `A2O_TEST_RUBY_SHARD_GRANULARITY=file` remains available as a fallback for custom Ruby commands that cannot use RSpec JSON dry-run discovery.
- Internal maintainability: Go host launcher agent target/install tests are split out of the remaining large `main_test.go`, and Ruby runtime artifact/log cleanup handlers are extracted from the root CLI module.

## Migration Notes

- Project packages that already define `runtime.prompts.repoSlots` should audit multi-repo tasks before upgrading. Multi-repo tasks receive every repo-slot addon in the task `repo_slots` / `edit_scope` order; earlier releases only applied a singular repo-slot layer. If slot-specific instructions conflict or become too broad when combined, split the work into repo-slot child tasks or adjust the package prompts. Use `a2o prompt preview --phase implementation --repo-slot app --repo-slot lib <task-ref>` before running workers to inspect the composed instruction.
- Project packages that use no-op `runtime.phases.implementation.skill` or `runtime.phases.review.skill` stubs only to satisfy validation may remove those stubs after defining the matching `runtime.prompts.phases.<phase>` prompt or skills. A system prompt alone is not enough; `a2o project validate` still fails with `runtime.phases.<phase>.skill must be provided` when neither a phase skill nor a matching phase prompt/skill exists.
- `a2o runtime start` and `a2o runtime stop` are no longer compatibility aliases. Use `a2o runtime resume` to resume the resident scheduler and `a2o runtime pause` to pause it after the current work. If the removed commands are invoked, A2O exits non-zero and prints `migration_required=true` with the replacement command.
- Custom workers must return `review_disposition.slot_scopes` as the review disposition scope field. `review_disposition.repo_scope` is not accepted in 0.5.69 worker results; migrate values such as `"repo_alpha"` to `slot_scopes: ["repo_alpha"]`, and multi-repo findings to all affected slot names. Validate saved worker results with `a2o worker validate-result --request request.json --result result.json --review-slot-scope <slot>`.
- SoloBoard-era Kanbalone compatibility names are removed. Use `KANBAN_BACKEND=kanbalone`, `KANBALONE_BASE_URL`, `KANBALONE_API_TOKEN`, `--kanbalone-port`, `A2O_BUNDLE_KANBALONE_PORT`, and `A2O_KANBALONE_INTERNAL_URL`. Removed SoloBoard inputs fail with `migration_required=true` and the replacement name.
- Bundled Kanbalone data names changed from `<compose-project>_soloboard-data` / `soloboard.sqlite` to `<compose-project>_kanbalone-data` / `kanbalone.sqlite`. If the old volume exists and the new one does not, `a2o kanban up` fails with `migration_required=true` instead of silently creating an empty board. Copy or rename the existing Kanban data before starting the bundled service.
- Public `A3_*` environment fallbacks for runtime, agent, worker, host package, and root utility configuration are removed where `A2O_*` replacements exist. Use `A2O_RUNTIME_IMAGE`, `A2O_COMPOSE_PROJECT`, `A2O_COMPOSE_FILE`, `A2O_RUNTIME_SERVICE`, `A2O_BUNDLE_AGENT_PORT`, `A2O_BUNDLE_STORAGE_DIR`, `A2O_SHARE_DIR`, `A2O_AGENT_PACKAGE_DIR`, `A2O_AGENT_TOKEN`, `A2O_AGENT_TOKEN_FILE`, `A2O_AGENT_CONTROL_TOKEN`, `A2O_AGENT_CONTROL_TOKEN_FILE`, `A2O_AGENT_*`, `A2O_WORKER_*`, `A2O_WORKSPACE_ROOT`, `A2O_ROOT_DIR`, and `A2O_ROOT_*` root utility controls. Removed `A3_*` inputs fail with `migration_required=true` and the replacement name.
- `A3_SHARE_DIR` is no longer accepted as a host package fallback. Use `A2O_SHARE_DIR` or pass `--share-dir`; the host install path now fails before copying launchers when only the removed `A3_SHARE_DIR` input is provided.
- `worker-runs.json` is no longer an activity state source. Operator diagnostics, cleanup, rerun readiness, reconcile, and watch-summary use `agent_jobs.json`; leftover `worker-runs.json` is reported with `migration_required=true`.
- Public agent package and host launcher artifacts use `a2o-agent` / `a2o` names. Release archives are named `a2o-agent-<version>-<os>-<arch>.tar.gz`, archives contain `a2o-agent`, host install writes `a2o` and `a2o-<os>-<arch>` only, shell installers remove stale `a3*` files from their install directory, and old package/cache environment names fail with `migration_required=true`. Runtime-image `a3 agent package ...` also fails with `migration_required=true`; use `a2o agent package ...`.
- Decomposition command execution now depends on the host launcher and packaged host agent. Upgrade the host launcher/shared assets and runtime image together before using `a2o runtime decomposition investigate`, `propose`, or `review`; otherwise an older host launcher may not recognize the decomposition host-agent command path. A typical upgrade is:
  - install the new launcher from the release image: `docker run --rm -v "$PWD/.work/a2o:/out" ghcr.io/wamukat/a2o-engine:0.5.69 a2o host install --output-dir /out/bin --share-dir /out/share`
  - update project runtime image references to `ghcr.io/wamukat/a2o-engine:0.5.69`
  - restart the runtime container with the new image before running decomposition commands.
- Decomposition draft acceptance in 0.5.69 enables generated-parent automation by default. After upgrading, `a2o runtime decomposition accept-drafts` adds `trigger:auto-parent` and the accepted child `repo:*` label union to the generated parent unless `--no-parent-auto` is passed. Update both the host launcher/shared assets and runtime image before relying on this behavior.
- External Kanbalone deployments used with decomposition source tickets should run Kanbalone v0.9.28 or newer. A2O writes `related` relations from the requirement source ticket to the generated implementation work and uses v0.9.28 `externalReferences` for imported-source provenance; older external Kanbalone versions do not provide the complete surface.
- Project packages that adopt `docs.surfaces` should validate that every surface `repoSlot` is backed by a configured repo source and that every cross-repo `docs.authorities.*.repoSlot` points at the repo containing the source-of-truth file. No migration is required for existing single-surface `docs` packages.
- To use `runtime.delivery.mode: remote_branch`, update the host launcher/shared assets and runtime image together, then add `runtime.delivery.remote`, `base_branch`, and optional `branch_prefix` / `after_push.command` to `project.yaml`. The `after_push.command` runs from the repo source root; use a PATH command, absolute path, or source-root-relative path.
- `publish.commit_hook_policy` was replaced before public release and is not accepted. Use `publish.commit_preflight.native_git_hooks` instead; invalid old keys fail fast during project package or agent request validation instead of silently changing publish commit hook behavior.

## Validation Scope

The reference product suite covers single-repo and multi-repo task flows through kanban, agent gateway, verification, merge, parent-child handling, runtime watch summary, describe-task diagnostics, and evidence persistence.

## Change Boundary

Open product work is tracked on the A2O kanban before implementation. External behavior changes require owner discussion before coding.
