# Worker Runs Legacy State Retirement

This note records the current `worker-runs.json` dependency map and the staged retirement plan.

`worker-runs.json` is not dead code yet. `agent_jobs.json` now covers claimed agent job heartbeats for watch-summary, but several operator utilities still use `worker-runs.json` as their active-worker evidence source.

## Current Readers And Writers

- `lib/a3/cli.rb`
  - `load_watch_summary_legacy_worker_runs` reads `worker-runs.json`.
  - `load_watch_summary_agent_job_runs` reads `agent_jobs.json`.
  - watch-summary merges both sources and keeps the newest heartbeat per task.
- `lib/a3/operator/root_utility_launcher.rb`
  - resolves the default `--worker-runs-file` path under `.work/a3/state/<project>/worker-runs.json`.
- `lib/a3/operator/diagnostics.rb`
  - reports worker run state for operator diagnostics.
- `lib/a3/operator/cleanup.rb`
  - treats worker run state as active-reference evidence before cleaning task artifacts.
- `lib/a3/operator/rerun_readiness.rb`
  - uses worker run records to resolve task IDs and assess rerun readiness.
- `lib/a3/operator/reconcile.rb`
  - reads worker run records during reconciliation.
  - writes updated worker run records after marking stale active runs.

## Retirement Decision

Do not remove `worker-runs.json` readers yet.

The current active-worker evidence replacement is incomplete because `agent_jobs.json` is wired into watch-summary for heartbeat display, but not into the operator utilities listed above. `agent_jobs.json` is already the runtime agent job store; the missing part is a shared activity-evidence reader for diagnostics, cleanup, rerun readiness, and reconcile. Operator utilities still need that common abstraction before `worker-runs.json` can be deleted without losing diagnostics, cleanup safety, or rerun readiness behavior.

## Staged Plan

1. Introduce an `AgentActivityStore` reader that can load both `agent_jobs.json` and `worker-runs.json` into one normalized model.
2. Move watch-summary, diagnostics, cleanup, rerun readiness, and reconcile onto that normalized reader.
3. Change new runtime writes to use `agent_jobs.json` only, while the reader still accepts `worker-runs.json`.
4. Add a migration or expiry policy for old `worker-runs.json` files.
5. Remove direct `worker-runs.json` reads and writes only after all operator utilities use the normalized reader/writer and old state has either migrated or aged out.

Until then, `worker-runs.json` is a compatibility state source, not unused functionality.
