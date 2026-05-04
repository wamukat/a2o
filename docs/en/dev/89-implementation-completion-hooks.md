# Implementation Completion Hooks

This design defines `runtime.phases.implementation.completion_hooks`, a project-package extension point that runs after the implementation worker returns and before A2O accepts the implementation for review.

## Problem

A2O currently lets a project define verification and remediation commands, and v0.5.70 added `publish.commit_preflight.commands`. Those surfaces are not the same as an implementation completion gate.

`publish.commit_preflight.commands` runs at publish-commit time. It can block publication, but it is too late to be a useful feedback loop for the implementation worker because the worker already reported success. The desired behavior is to let a project force checks or formatting between:

1. AI implementation worker finishes editing and returns a worker result.
2. A2O accepts the implementation, publishes the implementation commit, and advances toward review.

If a hook fails, A2O should feed the hook result back into implementation rework instead of advancing to reviewer review.

## User-Facing Configuration

The public configuration lives under the implementation phase:

```yaml
runtime:
  phases:
    implementation:
      completion_hooks:
        commands:
          - name: fmt
            command: ./project-package/commands/fmt-apply.sh
            mode: mutating
          - name: verify
            command: ./project-package/commands/impl-verify.sh
            mode: check
            on_failure: rework
```

`commands` is an ordered list. Each entry has:

- `name`: stable hook identifier, used in logs, diagnostics, and feedback.
- `command`: shell command string executed by the host agent.
- `mode`: `mutating` or `check`.
- `on_failure`: `rework` for the initial implementation. Future values may be added only after the state semantics are explicit.

The MVP accepts hooks only for `runtime.phases.implementation`. Review, verification, and merge hooks are separate design problems.

## Execution Point

For agent-materialized implementation jobs, the lifecycle becomes:

1. Materialize workspace.
2. Run implementation worker command.
3. Load worker result and uploaded artifacts.
4. Run `implementation.completion_hooks`.
5. Refresh slot evidence and canonical changed files.
6. Publish either the accepted implementation commit or a failed-attempt work ref, depending on the hook result.
7. Submit the implementation result to the runtime control plane.

Hooks must run before publish, not after publish. This lets mutating hooks contribute to the implementation commit and lets failed hooks produce implementation rework feedback before the reviewer phase starts.

When hooks fail, A2O still needs a source for the next rework run. The MVP must therefore publish the failed implementation attempt to an internal work ref without advancing the task to review. The failed-attempt ref is not a final implementation commit and is not merged or reviewed; it exists so the next implementation rework can start from the code the AI just produced plus any successful mutating hook output before the failing hook.

The failed-attempt ref should use the same work-branch namespace as normal implementation work and should be recorded in the execution diagnostics, for example `completion_hook_attempt_ref`. The next implementation run must use that ref as its source descriptor when the previous implementation outcome is `rework`.

## Command Workspace

The MVP executes each hook once per edit-target repo slot from that slot checkout root. The agent provides these environment variables:

- `A2O_WORKSPACE_ROOT`: root of the materialized workspace.
- `A2O_COMPLETION_HOOK_NAME`: configured hook name.
- `A2O_COMPLETION_HOOK_SLOT`: current repo slot.
- `A2O_COMPLETION_HOOK_MODE`: `mutating` or `check`.
- `A2O_WORKER_REQUEST_PATH`: worker request JSON path when available.
- `A2O_WORKER_RESULT_PATH`: worker result JSON path when available.

Commands that need multi-repo context should use `A2O_WORKSPACE_ROOT` and the request JSON `slot_paths` map. A future `scope: workspace` mode can be added after a concrete multi-repo use case requires one.

Ordering is deterministic and hook-major: A2O runs hook 1 for every edit-target slot in sorted slot-name order, then hook 2 for every edit-target slot, and so on. This preserves the configured sequence globally, so a package can express `fmt` before `verify` across all slots. Within each hook, slot order is lexical by repo slot name.

## Mutating vs Check Hooks

`mode: mutating` allows the hook to edit files under the current edit-target slot. Use it for formatting, generated code, or other deterministic post-processing that should be part of the implementation commit.

After a mutating hook succeeds, A2O refreshes workspace evidence and canonical changed files. The implementation publish uses the canonical changed files after hooks, not only the `changed_files` reported by the AI worker.

`mode: check` is non-mutating. A2O snapshots git state before and after the command. If a check hook changes staged or unstaged repo state, A2O treats the hook as failed and sends rework feedback. Use `mode: mutating` for commands that intentionally rewrite files.

## Failure and Rework

A hook failure does not advance the task to review.

When a hook exits non-zero, times out, or violates `mode: check`, the agent submits an implementation execution result equivalent to:

```json
{
  "success": false,
  "rework_required": true,
  "failing_command": "completion_hook:verify",
  "observed_state": "implementation_completion_hook_failed",
  "diagnostics": {
    "completion_hooks": [
      {
        "name": "verify",
        "slot": "app",
        "mode": "check",
        "exit_code": 1,
        "stdout": "...",
        "stderr": "..."
      }
    ]
  }
}
```

The runtime outcome for implementation `rework_required=true` must be `rework`, matching the existing review-to-implementation feedback shape. This requires an explicit runtime change: `PhaseExecutionOrchestrator` must map implementation failures with `rework_required=true` to outcome `rework`, and `PlanNextPhase` / run registration must preserve a rework source descriptor instead of treating the task as blocked. Without this change, hook failures will be misclassified as blocked.

The next implementation request carries the hook diagnostics in `phase_runtime.prior_review_feedback` or its successor feedback field so the AI can address the failure without parsing free-form comments. It must also materialize from the failed-attempt ref described above; otherwise the AI would lose the failed implementation it needs to repair.

The name `prior_review_feedback` is historically review-specific. The implementation may continue to populate it for compatibility, but the design should prefer a neutral internal concept such as `prior_phase_feedback` when adding new persisted evidence.

Timeout is intentionally simple in the MVP. Hooks use the existing agent job timeout budget; there is no per-hook timeout key. If a per-hook timeout becomes necessary, it must be added later with a documented default and maximum.

## Observability

Completion hook execution must be visible to operators:

- host-agent event log stages: `completion_hook_start`, `completion_hook_done`, and `completion_hook_error`;
- artifact uploads for hook combined logs when output is non-empty or a hook fails;
- `describe-task` execution diagnostics containing hook status, slot, mode, and failing command;
- Kanban activity comments for failed hooks through the existing blocked/rework comment path;
- enough structured data for `watch-summary --details` to show the task is waiting on implementation rework, not reviewer review.

Normal `watch-summary` does not need per-hook lines.

## Relationship to Publish Commit Preflight

`runtime.phases.implementation.completion_hooks` and `publish.commit_preflight` are different surfaces:

- completion hooks are an implementation lifecycle gate and can feed the AI implementation worker with rework input;
- completion hooks run before the implementation publish commit;
- mutating completion hooks are allowed when configured with `mode: mutating`;
- `publish.commit_preflight.commands` is a last publish safety check and must be check-only;
- preflight failures block publish, but they should not be presented as the primary AI feedback mechanism.

Projects can use both. A typical package uses completion hooks for format/test feedback and keeps publish preflight for final non-mutating guardrails.

## Acceptance Criteria

- Project package validation accepts the documented schema and rejects malformed hooks.
- Hook configuration propagates from `project.yaml` to the host launcher, runtime, Ruby workspace request, and Go agent request.
- Agent-materialized implementation jobs run hooks before publish.
- Mutating hooks can change files included in the implementation commit.
- Check hooks fail if they mutate files.
- Hook failures route to implementation rework and do not advance the task to review.
- User documentation explains how to configure and operate hooks.
