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

## What Is Stable Enough Today

The following are stable enough for continued migration work:

- generic `KANBAN_BACKEND=soloboard task kanban:*` operator surface
- SoloBoard bootstrap for `Portal`, `OIDC`, `A3Engine`
- SoloBoard parity smoke
- isolated A3 no-op canary on `.work/a3/portal-soloboard-canary`
- `plan-next-runnable-task` selection smoke against labeled SoloBoard tasks

## What Still Needs More Evidence

The following are not yet proven by a full end-to-end SoloBoard canary:

- full child `implementation -> verification -> merge`
- parent finalize on SoloBoard backend
- repeated scheduler-loop operation over time
- whether transition/relation confirmation also need retry hardening

## Current Judgment

Current judgment is:

- SoloBoard is usable as the next backend migration target
- the main observed instability is short-lived post-mutation read inconsistency
- this is not currently a blocker for continued migration work
- but it is still too early to call the backend fully production-ready for A3 without a full-phase isolated canary

## Recommended Next Checks

1. Run an isolated SoloBoard child canary through full phase completion.
2. Observe whether `transition`, `relation`, or `done` confirmation need the same retry treatment as labels.
3. Run a parent finalize canary on the same isolated storage.
4. Only after those pass, make the live backend cutover judgment.
