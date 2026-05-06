# Implementation Operator Proposals

This document defines the design for A2O#603 / GH#94: implementation workers need a structured way to tell operators about improvement proposals that should not block the current task and should not automatically become implementation work.

## Problem

During implementation, an AI worker can finish the requested change while noticing that the project policy, architecture rule, lint rule, dependency policy, or toolchain setting may be the real thing to improve.

Examples:

- The worker used an awkward workaround because an architecture rule forbids a dependency that may actually be acceptable.
- The worker split code unnaturally to satisfy a line-length rule that may be too strict for the project.
- The worker completed the task but found that a project command, verification policy, runtime policy, or architecture rule would make future work easier if adjusted.

Today the worker can put this in `summary`, but operators can miss it. It can also create or request `follow_up_child`, but that turns an optional proposal into implementation work.

## Design Decision

The MVP adds an optional `operator_proposals` field to worker results. It does not add a new `implementation-proposal` phase.

Reasons:

- A proposal should be visible to the operator without changing task success.
- The scheduler, phase model, review transition, and merge path should not grow a new phase before there is evidence that proposals need independent lifecycle state.
- Existing decomposition `author-proposal` / `review-proposal` is different: decomposition proposals create implementation planning artifacts. Implementation operator proposals are advisory notes unless a human chooses to act.

## Boundary With Existing Fields

Use `operator_proposals` when the worker wants a human to consider a project, process, policy, or architecture improvement after the current task.

Good fits include:

- project command, verification policy, runtime policy, or architecture rule proposals
- process or operating-policy adjustments that may make future A2O runs easier
- advisory alternatives that are useful to the operator but should not become runnable work automatically

Do not use it for:

- direct code follow-up that should become runnable implementation work: use `review_disposition.kind=follow_up_child` or the existing follow-up child path
- reusable prompt or skill tuning candidates: use `skill_feedback`
- design debt discovered in the changed code: use `refactoring_assessment`
- task-blocking ambiguity: use `clarification_request`
- implementation failure or rework feedback: use `success=false` and normal failure fields

The same worker result may contain both `operator_proposals` and a more specific field only when the concepts are genuinely different. For example, a worker may include `refactoring_assessment` for duplicated code in the current task and `operator_proposals` for relaxing a project lint rule that caused the workaround.

## Worker Result Contract

`operator_proposals` is optional and may be absent, `null`, an empty array, or an array of proposal entries. An empty array is equivalent to no proposals and must not produce evidence or comments.

Each entry has this MVP shape:

```json
{
  "title": "Relax ArchUnit rule for infrastructure annotations",
  "summary": "The current workaround is valid but makes the implementation less natural.",
  "description": "Allowing the selected annotation in the infrastructure package would remove the workaround and keep dependency direction intact.",
  "category": "architecture_policy",
  "priority": "low",
  "scope": ["repo_alpha:src/main/java/com/example/infrastructure"],
  "evidence": ["Changed FooAdapter to avoid the forbidden annotation."],
  "suggested_action": "Review the ArchUnit rule and decide whether the annotation should be allowed."
}
```

Required fields:

- `title`
- `summary`

Optional fields:

- `description`
- `category`
- `priority`: `low`, `medium`, `high`, or `urgent`
- `scope`: array of repo slots, paths, packages, commands, or policy names
- `evidence`: array of short strings
- `suggested_action`

Validation should be permissive about unknown optional fields only after the required fields are present and strings are non-empty. Invalid proposal entries should fail worker-result validation because otherwise the operator-facing evidence becomes unreliable.

## Lifecycle

For implementation success:

1. The implementation worker returns a valid worker result.
2. A2O validates `operator_proposals` along with the existing worker result contract.
3. A2O stores proposals in execution evidence and worker-result artifacts.
4. A2O posts a short Kanban comment on the source task when at least one proposal exists.
5. The task continues through the normal implementation-to-review path.

The proposal must not:

- change `success`
- force `rework_required`
- create child tickets automatically
- add trigger labels
- alter parent/child scheduling

For implementation failure, the MVP may preserve valid proposals in evidence but should not post the normal operator proposal comment. The operator's immediate action is the failure or rework path.

## Kanban Comment

The comment should be Markdown and compact. It should summarize up to a small fixed number of proposals and point operators to `describe-task` for full evidence.

Example:

```markdown
### A2O operator proposals

The implementation completed and reported 1 non-blocking proposal.

1. **Relax ArchUnit rule for infrastructure annotations** (`low`, `architecture_policy`)
   The current workaround is valid but makes the implementation less natural.

Full details are available in `a2o runtime describe-task A2O#123`.
```

Use `kanban.system_comment_locale` for the fixed system text. Proposal titles and summaries are worker-authored and should not be machine-translated by A2O.

## Runtime Visibility

`a2o runtime describe-task <task-ref>` should show pending operator proposals under the latest execution diagnostic. The display should include:

- proposal count
- title
- priority
- category
- suggested action
- evidence path or artifact reference when available

`watch-summary` should not show proposal details in the normal tree. A future `--details` view may show a compact count if operators ask for it.

## Future Extensions

Possible future work, intentionally outside the MVP:

- `a2o runtime operator-proposals list`
- `a2o runtime operator-proposals convert-to-ticket`
- project-package policy to auto-comment only selected categories
- project-package policy to require a reviewer for high-priority proposals
- a dedicated proposal review phase after real usage proves that comment-only routing is insufficient

## Implementation Tasks

Suggested child tickets for implementation:

1. Add worker result schema and semantic validation for `operator_proposals`.
2. Preserve proposals in execution evidence and `describe-task`.
3. Render localized Markdown Kanban comments for implementation success proposals.
4. Update project script contract, user docs, and release notes.
5. Add unit and real-task smoke coverage for a worker result that includes `operator_proposals`.
