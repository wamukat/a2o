# SoloBoard Observed Instability Notes

## Purpose

This note records the instability that was actually observed during the SoloBoard migration spike on 2026-04-10.
It is intentionally narrower than the main migration plan.
The goal is to distinguish:

- confirmed API defects
- CLI-side false negatives
- operator risks that still need canary coverage

## Scope

This note covers the current local SoloBoard spike at `http://127.0.0.1:3460` and the A3-facing compatibility surface implemented by:

- `Taskfile.yml`
- `scripts/kanban/kanban_cli.py`
- `scripts/kanban/bootstrap_soloboard.py`
- `scripts/kanban/soloboard_smoke.py`

## Confirmed Observations

### 1. Parent relation create/delete is currently usable

On SoloBoard `main` at commit `fd987da`, the following were confirmed in isolated sequential execution:

- raw `PATCH /api/tickets/{id}` with `{"parentTicketId": parentId}` works
- raw `PATCH /api/tickets/{id}` with `{"parentTicketId": null}` works
- CLI `task-relation-create` / `task-relation-delete` also work when checked sequentially

Earlier contradictory observations were caused by mixed verification steps, not by a reproducible active blocker in the API.

### 2. Mutation-after-read can briefly look inconsistent

The main instability that was actually observed was not a hard API failure, but short-lived read inconsistency immediately after mutation.

Concrete examples:

- `task-label-add` succeeded, but the immediate follow-up read sometimes did not include the newly added label yet
- `task-label-remove` had the same shape of false negative risk
- this made the CLI report:
  - `Task label assignment was not observed`
  - even though a later read showed the mutation had applied

### 3. The instability is currently most visible on operator confirmation paths

The issue did not primarily appear as:

- ticket create failure
- comment create failure
- relation create/delete failure
- transition failure

It appeared as:

- mutation succeeds
- immediate verification read is stale or slightly delayed
- operator CLI interprets that as a failure

This means the current risk is more about observation semantics than mutation semantics.

## Impact on A3

For A3, this matters because the kanban adapter does not only mutate.
It also needs to confirm that mutation became observable immediately enough for orchestration.

If the backend is eventually consistent at short timescales, these flows become fragile:

- label add/remove confirmation
- transition confirmation
- relation confirmation
- any canary that interprets one immediate read as final truth

Without mitigation, A3 can incorrectly classify a successful backend mutation as:

- blocked
- failed confirmation
- command contract mismatch

## Current Mitigation

The current mitigation is on the CLI side.

Implemented:

- `task-label-add` now retries observation before declaring failure
- `task-label-remove` now retries observation before declaring failure

This is intentionally narrow.
It does not assume broad backend inconsistency everywhere.
It only hardens the call sites where false negatives were actually observed.

## 2026-04-11 Bundle Agent Loop Evidence

The bundle agent loop exercises the normal A3 distribution shape: `docker:a3` as control plane, `docker:soloboard` as kanban, and `docker:dev-env(a3-agent)` as project command runtime.

Observed evidence:

- `ITERATIONS=1 INTERVAL_SECONDS=5 task a3:portal:bundle:agent-loop`
  - `Portal#44` worker gateway reached `Done`
  - `Portal#45` verification command runner reached `Done`
  - `Portal#46/#47/#48` parent topology reached `Done`
- `ITERATIONS=2 INTERVAL_SECONDS=10 task a3:portal:bundle:agent-loop`
  - first iteration: `Portal#49/#50/#51/#52/#53` reached `Done`
  - second iteration: `Portal#54/#55/#56/#57/#58` reached `Done`
- after each loop observation, `watch-summary` and `show-state` reported no active, queued, or blocked tasks
- host disk stayed at 93Gi available, Docker build cache reclaimable stayed at 667.2MB, and local volumes stayed around 115MB

No read-after-write false negative was observed for label, transition, relation, or done confirmation during these loops.

## What Is Stable Enough Today

The following are stable enough for continued migration work:

- generic `KANBAN_BACKEND=soloboard task kanban:*` operator surface
- SoloBoard bootstrap for `Portal`, `OIDC`, `A3Engine`
- SoloBoard parity smoke
- isolated A3 no-op canary on `.work/a3/portal-soloboard-canary`
- `plan-next-runnable-task` selection smoke against labeled SoloBoard tasks
- isolated single full-phase canary on `Portal#17`
- isolated parent-child canary on `Portal#18/#19/#20`
- bundle agent worker / verification / parent topology loops through `Portal#44` to `Portal#58`

## What Still Needs More Evidence

The following still need more evidence:

- repeated scheduler-loop operation over time
- whether `transition`, `relation`, or `done` confirmation also need the same retry hardening as labels under heavier write volume. Short bundle agent loops did not reproduce instability
- whether mainline non-isolated Portal storage can switch defaults without operational surprises

## Current Judgment

Current judgment is:

- SoloBoard is usable as the next backend migration target
- SoloBoard has already passed isolated single and parent-child end-to-end canaries
- the main observed instability is short-lived post-mutation read inconsistency
- this is not currently a blocker for continued migration work
- but it still needs longer-running scheduler evidence before calling the backend fully production-ready for A3

## Recommended Next Checks

1. Observe longer-running scheduler-loop operation on SoloBoard backend for drift or read-after-write gaps.
2. Keep transition/relation/done confirmation under observation during longer loops; short bundle agent loops did not reproduce instability.
3. Complete mainline cutover judgment for generic `task kanban:*`; Kanboard compatibility entrypoints are removed from current runtime.
4. Only after those hold, lock Docker/runtime packaging to SoloBoard.
