# Bounded Intra-Project Parallel Scheduler

This document defines the Phase B/C design for A2O#317. Phase A is already covered by the multi-project runtime model: one A2O installation may run one scheduler per project, while each project remains single-task by default. This document covers bounded parallel execution inside one project.

The goal is to let independent tasks in one project run concurrently without weakening the existing parent/child ordering, blocker handling, run recovery, or merge safety.

## 1. Scope

The first intra-project parallel scheduler must be conservative.

- Default behavior remains equivalent to `max_parallel_tasks: 1`.
- `max_parallel_tasks > 1` allows multiple independent task groups to execute workspace phases concurrently.
- Tasks in the same parent group are still single-threaded.
- A parent task and any of its children are mutually exclusive.
- Merge and publish-to-shared-ref operations remain serialized.
- Decomposition remains a separate serial domain unless a later design explicitly changes it.
- Cross-machine distributed scheduling is out of scope.

## 2. Configuration

The user-facing configuration is intentionally small:

```yaml
runtime:
  scheduler:
    max_parallel_tasks: 2
```

`max_parallel_tasks` counts active task runs inside the resolved project. The default is `1`.

The MVP must not add per-phase, per-repo, or per-parent concurrency settings. Those knobs can be added later only if real usage proves that the simple limit is insufficient.

## 3. Current Limitation

The current scheduler is sequential:

1. `SchedulerCycleExecutor` loops up to `max_steps`.
2. Each loop calls `ExecuteNextRunnableTask`.
3. `ScheduleNextRun` asks `PlanNextRunnableTask` for one candidate.
4. `StartRun` / `RegisterStartedRun` create a run and write `task.current_run_ref`.
5. The same call stack executes the phase synchronously.

This is safe for one active task, but it is not a parallel claim protocol. In particular:

- `PlanNextRunnableTask` returns one candidate, so it cannot filter conflicts within a selected batch.
- `current_run_ref` is only written after a run record is saved, so split writes can leave half-started state.
- JSON task storage has no compare-and-swap or file lock around claim updates.
- Parent group exclusion currently depends on persisted running siblings; a batch planner could select conflicting siblings before either is persisted as running.
- Merge and implementation publish are shared-ref operations and need an explicit runtime lock.

## 4. Claim Model

Parallel scheduling needs a durable claim before execution starts. A claim is not the same as a run. The claim says "this scheduler process owns this task slot"; the run says "this phase execution exists and has evidence."

Add a task claim record with:

- `claim_ref`
- `project_key`
- `task_ref`
- `phase`
- `parent_group_key`
- `state`: `claimed`, `released`, `stale`
- `claimed_by`
- `claimed_at`
- `heartbeat_at`
- `run_ref`
- `stale_reason`

The claim is acquired before run creation. A scheduler may start a run only after it owns a live claim for the task and phase. When run startup succeeds, the claim is linked to `run_ref`.

The claim acquisition API must be atomic for the backing store:

```ruby
claim_task(task_ref:, phase:, parent_group_key:, claimed_by:, now:)
release_claim(claim_ref:, run_ref: nil)
mark_claim_stale(claim_ref:, reason:)
active_claims
```

For SQLite storage, use a transaction plus uniqueness constraints over active task refs and active parent group keys. The parent group constraint is required even if the in-process batch planner already filters conflicts, because overlapping scheduler commands, repair leftovers, or a foreground `run-once` can otherwise create same-group claims through separate processes. For JSON storage, add file locking before enabling `max_parallel_tasks > 1`; otherwise JSON mode must reject parallel scheduler config with a clear diagnostic.

## 5. Conflict Keys

The planner must reserve conflict keys while building a batch. It cannot rely only on already-persisted running tasks.

Task conflict keys:

- task key: `task:<task_ref>`
- parent group key:
  - parent task: `parent-group:<task_ref>`
  - child task: `parent-group:<topmost_parent_ref>`
  - single task: `single:<task_ref>`
- shared-ref key for merge/publish: `shared-ref:<repo_slot>:<target_ref>`

Batch selection rules:

- Do not select a candidate if any active claim or active run already uses its task key.
- Do not select a candidate if any active claim or active run already uses its parent group key.
- While selecting a batch, reserve keys for each selected candidate so later candidates cannot conflict with earlier selected candidates.
- Preserve existing scheduler ordering by applying `SchedulerSelectionPolicy` before conflict filtering.
- Blockers and `needs:clarification` behavior remain part of `RunnableTaskAssessment`.

## 6. Batch Planner

Add `PlanRunnableTaskBatch` rather than changing the current single-task planner in place. The existing `PlanNextRunnableTask` remains the compatibility path for `max_parallel_tasks: 1`.

Inputs:

- all task assessments
- active runs
- active claims
- `max_parallel_tasks`
- current active slot count

Output:

- ordered selected candidates
- skipped conflict diagnostics
- assessment list for status/watch-summary

The selected batch size is:

```text
max_parallel_tasks - active_claim_or_run_count
```

If the available slot count is zero, the scheduler is busy rather than idle.

## 7. Execution Model

The scheduler should split selection from execution:

1. Repair stale runs and stale claims.
2. Build a candidate batch.
3. Atomically claim each selected task.
4. Start a run for each claim.
5. Execute phase work in bounded workers.
6. Release the claim after terminal run completion or stale repair.

The first implementation can keep one scheduler process and an in-process worker pool. It does not need cross-process distributed workers.

`max_steps` should count terminal phase executions, not worker loop ticks. If a run is still active when `max_steps` is reached, the scheduler stops claiming new work and waits only for already-started workers when the command is a foreground `run-once`. Background scheduler loops may leave active workers to complete under the same process.

## 8. Merge and Publish Serialization

Merge and implementation publish both touch shared refs. They must use a runtime lock even when the task claim system allows multiple active implementation or verification runs.

Add a shared-ref lock with:

- `lock_ref`
- `project_key`
- `operation`: `publish` or `merge`
- `repo_slot`
- `target_ref`
- `run_ref`
- `claimed_at`
- `heartbeat_at`

The lock is acquired immediately before the shared-ref operation and released immediately after it. A task may continue to own its task claim while waiting for the shared-ref lock; status surfaces should show `waiting_for_shared_ref_lock`.

## 9. Recovery

Recovery must handle four partial states:

1. claim exists, no run linked
2. claim exists, run linked but task has no `current_run_ref`
3. task has `current_run_ref`, but no live claim
4. run is active, worker process/job is stale

`RepairRuns` should expand into a scheduler repair pass that can mark stale claims and reconcile claim/run/task references. The repair result must be visible in status and watch-summary. Automatic repair should be conservative: if two live records claim the same task or parent group, A2O should block with a clear diagnostic rather than guessing.

## 10. Operator Surfaces

Status and watch-summary must distinguish:

- idle: no runnable candidates and no active runs
- busy: active claims/runs fill the configured slots
- waiting: candidates exist but conflict with parent group or shared-ref locks
- stale: claim or run repair is required

Minimum additions:

- `runtime status` shows `max_parallel_tasks`, active slot count, and claim/run refs.
- `watch-summary --details` shows claim age, parent group key, waiting conflict, and shared-ref lock holder.
- default `watch-summary` remains compact and only shows task tree state plus active run count.
- `show run` and `show task` include claim ref when present.

## 11. Implementation Breakdown

Recommended child ticket order:

1. Add scheduler config parsing and validation for `runtime.scheduler.max_parallel_tasks`.
2. Add durable task claim repository and stale claim diagnostics.
3. Add parent-group conflict keys and batch runnable planning.
4. Add bounded scheduler worker pool while preserving `max_parallel_tasks: 1`.
5. Add shared-ref publish/merge serialization lock.
6. Extend status/watch-summary/show surfaces for multiple active runs and claims.
7. Add integration tests for independent tasks, same-parent exclusion, duplicate-claim prevention, stale claim repair, and merge serialization.

Do not enable `max_parallel_tasks > 1` until the claim repository, conflict-key batch planner, and shared-ref publish/merge lock are all in place.
