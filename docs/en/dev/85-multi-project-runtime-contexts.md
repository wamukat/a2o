# Multi-Project Runtime Contexts

This document defines the target design for running multiple local projects from one A2O installation while preserving the current single-project workflow.

The design goal is not full SaaS-style multi-tenancy. A2O remains a local development runtime. The change is that one A2O installation can know about multiple project contexts, and each agent session or command can be bound to one of them.

## Problem

Today, a bootstrapped A2O instance effectively has one project package, one set of repo sources, one Kanban board, one storage area, and one runtime interpretation of task refs. That is simple and safe for solo development, but it does not fit a local workstation that hosts several projects and several connected agents.

The risky part is not adding another config field. The risky part is that project identity affects every side-effect boundary:

- project package and skills
- live repo and repo slots
- Kanban board and label vocabulary
- runtime storage, evidence, metrics, logs, and artifacts
- scheduler selection and locks
- branch namespace and merge targets
- hook cwd and environment
- task refs and remote issue mappings

If any of these remain implicitly global, A2O can process one project's ticket while writing to another project's repo or board.

## Goals

- Support multiple named project contexts in one A2O installation.
- Preserve the existing single-project command behavior as the default path.
- Make project identity explicit in runtime state before adding agent auto-binding.
- Let agent sessions and manual commands resolve to exactly one project context.
- Keep project package schema focused on product behavior; multi-project registration is runtime installation config.
- Partition side effects by project key.
- Design the target model first, then implement it in safe phases.

## Non-Goals

- Remote team-workflow tracking across projects.
- Cross-project task scheduling in the first implementation phase.
- Cross-project dependencies or blockers.
- Shared writable workspaces between projects.
- Per-user authorization or SaaS multi-tenancy.
- Letting project packages redefine scheduler, evidence, or Kanban provider behavior.

## Vocabulary

`ProjectDefinition`
: A runtime installation record that names a local project and points to its project package, repo sources, Kanban board, and storage partition.

`ProjectKey`
: Stable, human-readable identifier for a project definition. It is not derived from a Kanban board id or filesystem path.

`ProjectRuntimeContext`
: The fully resolved runtime context for one project. It contains the existing `ProjectContext` plus runtime-owned boundaries such as board id, repo sources, storage paths, branch namespace, and adapter clients.

`AgentBinding`
: Mapping from an agent identity or session to a default project key.

`ProjectRegistry`
: Runtime-owned registry that loads project definitions and resolves a project key into a `ProjectRuntimeContext`.

## Target Configuration Shape

Multi-project registration belongs to the A2O runtime installation, not to `project.yaml`.

Example shape:

```yaml
version: 1
default_project: a2o

projects:
  a2o:
    package_path: /Users/takuma/workspace/a2o/project-package
    storage_dir: /Users/takuma/workspace/a2o/.work/a2o/projects/a2o
    kanban:
      mode: external
      url: http://127.0.0.1:3470
      board_id: 2
      project: A2O
      task_ref_prefix: A2O
    repo_sources:
      app:
        path: /Users/takuma/workspace/a2o

  kanbalone:
    package_path: /Users/takuma/workspace/kanbalone/project-package
    storage_dir: /Users/takuma/workspace/a2o/.work/a2o/projects/kanbalone
    kanban:
      mode: external
      url: http://127.0.0.1:3470
      board_id: 4
      project: Kanbalone
      task_ref_prefix: KAN
    repo_sources:
      app:
        path: /Users/takuma/workspace/kanbalone

agent_bindings:
  codex-a:
    default_project: a2o
  codex-b:
    default_project: kanbalone
```

The Phase 1 host launcher registry file is `.work/a2o/project-registry.json`. The important constraint is that this config is runtime-owned installation metadata. A project package remains portable and describes one product's execution surface.

Kanban identity must include both the stable board identity and the adapter/display identity needed by the current provider. `board_id` identifies the board when the provider exposes one. `project` and `task_ref_prefix` preserve the existing Kanban CLI/ref contract, where selection and refs may still use names such as `A2O` and `A2O#297`.

## Context Resolution

Every command or agent request must resolve exactly one project key before it can touch Kanban, Git, storage, logs, hooks, or scheduler state.

Resolution order:

1. Explicit command/request project key.
2. Agent session binding.
3. Runtime default project.
4. Legacy single-project instance.

If multiple projects can match a task ref or no project can be determined, A2O fails before side effects.

The resolved project key is copied into run state, evidence, metrics, logs, workspace descriptors, and agent request bundles. It is not kept only in process memory.

## Runtime Context Contents

`ProjectRuntimeContext` should contain:

- `project_key`
- loaded project package path and manifest path
- existing domain `ProjectContext`
- repo sources and repo slot aliases
- Kanban adapter instance and board identity
- project storage root
- workspace root
- evidence/log/artifact roots
- branch namespace component
- hook execution cwd/env base
- scheduler group or lock namespace
- runtime package compatibility metadata

Existing code that accepts a naked `ProjectContext`, repo source map, storage dir, or Kanban adapter should move toward accepting a `ProjectRuntimeContext` or a narrower value derived from it.

## Side-Effect Partitioning

Project key must partition all durable and mutable side effects.

| Boundary | Required rule |
| --- | --- |
| Kanban | A task operation uses only the board configured for the resolved project. |
| Git repo slots | Repo aliases resolve only inside the selected project context. |
| Branches | User-visible branch namespace includes the project key or an equivalent collision-proof runtime instance component. |
| Storage | Runtime DB/files, evidence, metrics, logs, workspaces, and artifacts are stored under the project storage root. |
| Locks | Scheduler and task locks include the project key. |
| Hooks | Hook cwd/env are built from the selected project package and repo sources. |
| Agent requests | Request payloads include project key and project-scoped paths. |
| Cleanup | Cleanup commands never cross project storage roots unless explicitly asked to operate on all projects. |

## Task Ref Handling

Task refs are not globally unique across projects. `A2O#297` on one board and `A2O#297` on another board are different local tasks. The durable identity for an A2O task is the composite `(project_key, task_ref)`.

User-facing commands should accept:

```text
--project a2o A2O#297
a2o:A2O#297
```

The unqualified form remains valid only when a project can be resolved from command context. Ambiguous unqualified refs must fail.

Runtime state should store:

```json
{
  "project_key": "a2o",
  "task_ref": "A2O#297",
  "kanban_board_id": 2
}
```

To preserve existing store compatibility, records without `project_key` are read as legacy single-project records. If a multi-project registry is active and a legacy record would be ambiguous, A2O should require an operator migration instead of guessing. Storage indexes must migrate toward composite identity without rewriting legacy records in place during normal reads.

## Scheduler Model

The target model supports one scheduler per project context. Phase A allows multiple project schedulers to run from one A2O installation while each project still keeps the existing single active task policy. This is project-level concurrency, not intra-project task parallelism.

Phase A behavior:

- `runtime resume --project <key>` runs one project scheduler.
- `runtime resume --all-projects` starts one scheduler for each project in `.work/a2o/project-registry.json`.
- `runtime pause --project <key>` pauses one project scheduler without terminating the current scheduler process.
- `runtime pause --all-projects` pauses every registered project scheduler.
- `runtime status --all-projects` prints read-only, project-labelled status rows for every registered project.
- `runtime watch-summary --project <key>` shows one project.
- Each scheduler uses project-scoped pid, command, and log files under `.work/a2o/projects/<project>/scheduler`.
- Multi-project lifecycle commands require unique effective `compose_project` and host `agent_port` values for every registered project. A2O fails before starting schedulers if missing values would fall back to shared defaults or explicit values collide.

Phase A deliberately does not allow more than one active task inside the same project. Phase B must separately design bounded intra-project task parallelism, including durable task claims, parent/child group exclusion, and merge/publish serialization. Phase C must broaden status, watch-summary, logs, and stale-claim diagnostics for multiple active runs.

## Agent Binding

Agent binding is a convenience layer over explicit project resolution.

Target rules:

- Agent session may have a default project key.
- Request metadata may override the default project only when allowed by runtime policy.
- A2O records the project key in every run created through the agent.
- If an agent has no binding and no explicit project, requests fail unless a runtime default project exists.

Agent binding should not be implemented before project-scoped runtime state is durable.

## Backward Compatibility

Existing single-project installs must keep working.

Compatibility rules:

- If no multi-project registry exists, A2O behaves as it does today.
- Existing `.work/a2o/runtime-instance.json` remains a valid single-project instance.
- `project.yaml` schema does not need a breaking change.
- Commands without `--project` continue to work in single-project mode.
- Migration to a registry is explicit and reversible until the operator opts in.
- `tasks.json`, `runs.json`, and SQLite records without `project_key` remain readable as legacy single-project records.

## Guardrails

A2O must fail fast when guardrails detect a mismatch:

- task belongs to a board different from the resolved project board
- repo slot alias is missing in the selected project
- hook command resolves outside the selected project package contract
- storage root is shared by two project keys
- branch namespace would collide with another project
- command attempts to use unqualified task ref while multiple projects are active
- scheduler lock is already held for the same project
- agent queue or artifact store attempts to claim projectless jobs while multi-project mode is active

Guardrail failures should be reported as configuration errors, not worker failures.

## Implementation Phases

### Phase 0: Design And Inventory

- Document the target model.
- Inventory global assumptions in config loading, runtime services, Kanban adapters, storage, scheduler, agent requests, and CLI.
- Add no behavior yet.

### Phase 1: Project Registry And Explicit Context

- Add runtime-owned project registry types.
- Support exactly one default project through the registry.
- Add `--project` parsing to read-only diagnostic commands first.
- Store resolved project key in new task, run, evidence, metrics, scheduler cycle, agent job, artifact metadata, workspace descriptor, and log index records where those records exist.
- Keep old records readable through legacy single-project interpretation.
- No agent binding and no multi-project scheduler yet.

### Phase 2: Project-Scoped Side Effects

- Move storage roots, logs, workspaces, evidence, metrics, and locks under project storage roots.
- Make Kanban adapter construction project-scoped.
- Make repo source resolution project-scoped.
- Make agent queue and artifact stores project-scoped.
- Add guardrails for board/repo/storage mismatches.
- Do not enable multiple project definitions for write or lifecycle commands until repository keys, queue/artifact namespaces, scheduler pid/log paths, and cleanup selectors are project-scoped.
- Keep single-project mode as the default.

### Phase 3: Manual Multi-Project Operation

- Allow explicit `--project` on lifecycle commands such as `run-once`, `resume`, `describe-task`, `logs`, and `clear-logs`.
- Allow multiple project definitions in the registry.
- Still require explicit project selection for write operations.

### Phase 4: Agent Binding

- Add agent/session default project binding.
- Allow request-level explicit project override under policy.
- Record project key in agent request bundles and worker results.

### Phase 5: Optional Cross-Project Convenience

- Add `status --all-projects` or read-only summaries across projects.
- Consider multi-project scheduler supervision only after project-scoped locking is stable.

## Current Inventory Notes

Static review found these strong single-project assumptions:

- The Go launcher `runtime-instance.json` model stores one package path, workspace root, Kanban configuration, and storage location.
- `buildRuntimeRunOncePlan` aggregates package, config, storage, Kanban, repo sources, logs, and agent workspace into one plan.
- Ruby task/run repositories key records by `task.ref` or `run.ref` alone.
- Agent job and artifact stores do not have a project namespace.
- Scheduler pid/log/command paths are fixed under the workspace root.
- Kanban CLI adapters are built for one project, board, and repo label map.

Because of this, implementation must not start with agent binding. It must first carry project key through durable records and side-effect boundaries.

## Implementation Inventory Checklist

Use this checklist to keep later implementation tickets aligned with the static inventory above. Phase 0 does not change behavior; it only fixes the file/module map that later phases must follow.

| Area | Current single-project assumption | Primary files/modules | Later phase action |
| --- | --- | --- | --- |
| Runtime instance loading | One `runtime-instance.json` resolves to one package path, workspace root, Compose project, Kanban endpoint, and storage dir. | `agent-go/cmd/a3/internal_runtime.go` (`runtimeInstanceConfig`, `loadInstanceConfigFromWorkingTree`, `applyAgentInstallOverrides`) | Phase 1 adds a runtime-owned registry and resolves exactly one project key before building any runtime plan. |
| Runtime plan construction | `buildRuntimeRunOncePlan` flattens package config, repo sources, Kanban project/status, storage dir, log roots, agent workspace, branch namespace, and worker command into one unscoped plan. | `agent-go/cmd/a3/internal_runtime.go` (`runtimeRunOncePlan`, `buildRuntimeRunOncePlan`, `buildRuntimeDescribeTaskPlan`, `packageRuntimeRepoArgs`) | Phase 1 introduces a `ProjectRuntimeContext` input or equivalent narrow values; Phase 2 moves storage/log/workspace/artifact roots under the project storage root. |
| Scheduler process files | Resident scheduler pid, command, and log files are fixed under `<workspace>/.work/a2o-runtime`. | `agent-go/cmd/a3/internal_runtime.go` (`schedulerPaths`, `runRuntimeResume`, `runRuntimePause`, `runRuntimeStatus`, `overlaySchedulerWatchSummaryState`) | Phase 2 makes scheduler pid/log/command paths project-scoped before enabling multiple writable projects. |
| Runtime process cleanup | Runtime pid files, server logs, run logs, exit files, archive paths, and process patterns operate on one plan. | `agent-go/cmd/a3/internal_runtime.go` (`cleanupRuntimeProcesses`, `archiveRuntimeStateIfRequested`, `repairRuntimeRuns`, `killRuntimePIDFile`) | Phase 2 restricts cleanup/archive/repair to the resolved project storage root and process namespace. |
| Kanban command boundary | Kanban reads/writes use one `KanbanProject` and one provider URL; task refs are resolved in that project. | `agent-go/cmd/a3/internal_runtime.go` (`runtimeDecompositionKanbanOptions`, `runtimeWatchSummaryArgs`, `printDescribeKanbanSection`); `lib/a3/infra/kanban_cli_*` | Phase 1 records board identity on new records; Phase 2 builds adapters from the resolved project context and checks board/ref mismatches. |
| Task and run identity | JSON stores key tasks by `task.ref`; runs are keyed by `run.ref` and reference `task_ref` without project identity. | `lib/a3/infra/json_task_repository.rb`, `lib/a3/infra/json_run_repository.rb`, `lib/a3/infra/sqlite_task_repository.rb`, `lib/a3/infra/sqlite_run_repository.rb`, `lib/a3/adapters/task_record.rb`, `lib/a3/adapters/run_record.rb` | Phase 1b stores `project_key` and `kanban_board_id` on new records while reading legacy records as single-project records. |
| Scheduler state and cycles | Scheduler state and cycle journals are bound to one storage backend/path. | `lib/a3/infra/json_scheduler_store.rb`, `lib/a3/infra/sqlite_scheduler_store.rb`, `lib/a3/application/scheduler_cycle_journal.rb`, `lib/a3/application/scheduler_loop.rb` | Phase 1b adds project identity to new scheduler cycles; Phase 2 scopes scheduler locks/state paths by project. |
| Metrics and evidence | Metrics, blocked diagnoses, decomposition evidence, and recovery evidence derive identity from `task_ref`, `run_ref`, or storage path. | `lib/a3/infra/json_task_metrics_repository.rb`, `lib/a3/infra/sqlite_task_metrics_repository.rb`, `lib/a3/application/collect_task_metrics.rb`, `lib/a3/application/report_task_metrics.rb`, `lib/a3/application/*decomposition*`, `lib/a3/application/*recovery*` | Phase 1b persists project identity on new metrics/evidence; Phase 2 keeps evidence roots under project storage. |
| Agent job queue | Agent job records and claim order are stored in one queue without project namespace. | `lib/a3/infra/json_agent_job_store.rb`, `lib/a3/domain/agent_job_request.rb`, `lib/a3/domain/agent_job_record.rb`, `lib/a3/agent/http_control_plane_client.rb`, `lib/a3/operator/stdin_bundle_worker.rb` | Phase 1b adds project key to new requests/jobs; Phase 2 prevents projectless claims when a multi-project registry is active. |
| Agent artifacts | Artifact metadata and blobs are stored under one root keyed by artifact id. | `lib/a3/infra/file_agent_artifact_store.rb`, `lib/a3/domain/agent_artifact_upload.rb`, `lib/a3/application/build_artifact_owner.rb` | Phase 1b stores project identity in new artifact metadata; Phase 2 partitions artifact roots by project. |
| Workspace and branch materialization | Workspace roots, issue workspaces, quarantine paths, and branch namespaces are derived from the single runtime plan or task ref. | `lib/a3/application/build_workspace_plan.rb`, `lib/a3/application/prepare_workspace.rb`, `lib/a3/infra/local_workspace_provisioner.rb`, `lib/a3/operator/rerun_workspace_support.rb`, `agent-go/cmd/a3/internal_runtime.go` (`defaultBranchNamespace`) | Phase 2 scopes workspace/quarantine roots and branch namespaces by project key. |
| CLI option parsing | Runtime lifecycle and inspection commands accept task refs without project qualification. | `agent-go/cmd/a3/main.go`, `agent-go/cmd/a3/internal_runtime.go`, `lib/a3/cli.rb`, `lib/a3/cli/command_router.rb` | Phase 1 starts with read-only `--project`; Phase 3 extends explicit `--project` to write/lifecycle commands. |

Implementation sequence guardrail: A2O#311 and A2O#312 must introduce durable project identity before A2O#313 partitions side effects. A2O#315 agent binding remains blocked until explicit manual multi-project operation is available through A2O#314.

## Open Questions

- Where should the registry file live relative to the existing runtime instance file?
- Should branch namespaces use project key directly, runtime instance id, or both?
- How should project keys be renamed, if at all?
- Should Kanban board display refs include project prefix in multi-project mode?
- What is the minimum capability needed from `a2o-agent` to carry project key through execution?
- Should external Kanbalone with many boards be the recommended multi-project topology?

## Review Checklist

- No side effect can happen before project resolution.
- Unqualified task refs cannot cross project boundaries.
- Existing single-project commands remain valid.
- Project package schema remains project-owned and does not become runtime registry config.
- Agent binding is layered on top of durable project context, not the foundation.
- Implementation phases do not require a later breaking redesign.
