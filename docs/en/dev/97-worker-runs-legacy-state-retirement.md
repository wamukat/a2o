# Worker Runs Legacy State Retirement

This note records the current `worker-runs.json` dependency map and the staged retirement plan.

`worker-runs.json` is retired as an activity state source. Operator utilities now read normalized activity evidence from `agent_jobs.json`.

## Current Readers And Writers

- `lib/a3/operator/activity_evidence.rb`
  - reads `agent_jobs.json` and normalizes queued, claimed, and completed agent jobs into activity records.
- `lib/a3/cli.rb`
  - watch-summary uses claimed `agent_jobs.json` heartbeats only.
- `lib/a3/operator/diagnostics.rb`, `cleanup.rb`, `rerun_readiness.rb`, and `reconcile.rb`
  - use normalized activity evidence instead of parsing `worker-runs.json`.

## Retirement Decision

Do not reintroduce `worker-runs.json` readers or writers.

If `worker-runs.json` is present, diagnostics report `migration_required=true` with the replacement `agent_jobs.json` path. Reconcile no longer writes stale state back to `worker-runs.json`; it clears `active-runs.json` and relies on current agent job state for activity evidence.

## Current Policy

1. Use `agent_jobs.json` for runtime activity evidence.
2. Treat `worker-runs.json` as removed state that requires migration.
3. Keep any old `--worker-runs-file` option names only as command-line compatibility for locating the adjacent `agent_jobs.json` file and for reporting the removed-state diagnostic.
