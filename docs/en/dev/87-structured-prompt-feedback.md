# Structured Prompt Feedback Design

## Status

Future-facing design. This does not block the initial project-package prompt configuration release.

## Goal

Capture structured evidence about where prompt guidance failed or was insufficient, so project-package maintainers can improve prompts and skills later. The first version is read-only and reporting-oriented. It must not rewrite prompt files automatically.

## Event Model

Each feedback event is tied to a task, run, phase, prompt identity, and observed outcome.

```json
{
  "event_type": "review_finding",
  "severity": "warning",
  "task_ref": "A2O#123",
  "run_ref": "run-abc",
  "phase": "review",
  "prompt": {
    "profile": "implementation_rework",
    "effective_profile": "implementation",
    "fallback_profile": "implementation",
    "repo_slot": "app",
    "schema_version": "1",
    "composed_instruction_sha256": "..."
  },
  "category": "missing_verification",
  "summary": "Implementation did not run the focused test named in the ticket.",
  "source": "review_result",
  "evidence_ref": "agent-artifact:..."
}
```

Initial `event_type` values:

- `schema_invalid`: worker result JSON was missing required fields or had invalid identity.
- `unclear_requirement`: worker requested human clarification or could not infer the expected behavior.
- `review_finding`: review found a bug, missing acceptance coverage, unsafe compatibility change, or missing tests.
- `rework_required`: implementation had to run again because review feedback was not satisfied.
- `missing_verification`: implementation or remediation lacked the expected proof.
- `excessive_scope`: worker changed files or modules outside the intended ownership.
- `unsafe_instruction_conflict`: project/ticket guidance attempted to override A2O schema, workspace, branch, Kanban, review, or verification constraints.
- `human_clarification_needed`: A2O cannot proceed without a product or operator decision.

Recommended `category` values are stable strings, not free-form prose: `schema_invalid`, `ambiguous_requirement`, `acceptance_gap`, `missing_test`, `missing_verification`, `compatibility_risk`, `scope_creep`, `unsafe_override`, `docs_gap`, `migration_gap`, and `human_decision`.

## Capture Points

- Implementation: invalid result schema, excessive scope, missing verification, unsafe instruction conflict.
- Review: finding category, severity, affected file/path, whether rework is required.
- Rework: whether prior review findings were addressed, repeated finding category, new regressions.
- Decomposition: unclear requirement, child draft rejected, missing ownership, excessive child scope.
- Parent review: child integration gap, sequencing conflict, duplicated child work, missing migration/release guidance.

## Storage

Use layered storage so normal Kanban comments stay concise:

- Run artifacts: canonical JSONL feedback records. This is the durable source for analysis.
- Execution diagnostics: summarized counts and prompt identity fields only.
- Kanbalone structured logs or ticket comments: rendered summaries such as `prompt_feedback category=missing_verification count=1 prompt=implementation_rework sha256=...`.

Do not store raw prompt bodies in normal Kanban comments. Raw worker request artifacts continue to follow the existing artifact retention and access policy.

## Prompt Fingerprint Linkage

Every event should embed the prompt metadata recorded by worker evidence:

- requested `profile`
- `effective_profile`
- `fallback_profile`, when present
- `repo_slot`, when present
- project package schema version
- composed instruction SHA-256 and byte count
- per-layer kind, title/path, SHA-256, and byte count

This makes prompt changes detectable between runs without reading the current filesystem state.

## User-Visible Surfaces

Initial read-only surfaces:

- `describe-task`: show recent feedback categories and the prompt fingerprint that produced them.
- `watch-summary --details`: show compact blocked/rework feedback categories only when details are requested.
- future `runtime prompt-feedback list`: filter by category, prompt profile, repo slot, task, or parent.
- future `runtime prompt-feedback export`: JSONL/CSV export for offline prompt tuning.

The first implementation should not create draft prompt edits. A later workflow may propose prompt or skill changes, but only as reviewable artifacts or tickets.

## Non-Goals

- Automatic prompt rewriting.
- Mutating project-package prompt files from runtime feedback.
- Treating every review finding as a prompt failure. Some findings are code, test, product, or ticket-quality issues.
- Storing raw prompt content in Kanban comments.

## Open Questions

- Whether feedback records should be stored in the existing analysis artifact root or a dedicated prompt-feedback store.
- Whether Kanbalone should receive first-class structured feedback fields, or only rendered comments in the first release.
- How long prompt feedback artifacts should be retained relative to AI raw logs and execution metadata.

