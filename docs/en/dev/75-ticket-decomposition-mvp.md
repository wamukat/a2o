# Ticket Decomposition MVP

This document defines the MVP design for automated ticket decomposition, tracked by A2O#225 and GitHub issue #15.

The feature turns a high-level requirement ticket into a reviewed child-ticket proposal before implementation starts. The first release must prove the scheduling and review shape without making ticket creation or implementation unsafe.

## Problem

Today A2O executes already-scoped kanban tasks. When a user creates a large requirement ticket, the work of investigation, decomposition, child-ticket creation, and implementation planning still depends on one-off human or agent prompting.

That creates two failure modes:

- large tickets enter implementation before their boundaries and dependencies are understood
- implementation work can occupy runtime attention while ticket decomposition work waits, even though the two activities can proceed independently

The MVP must therefore introduce decomposition as its own runtime concern, not as a disguised implementation phase.

## Goals

- Detect high-level requirement tickets marked with `trigger:investigate`.
- Run a project-owned investigation command to collect product-specific context.
- Produce a proposed ticket tree with child scopes, dependencies, labels, verification expectations, and acceptance criteria.
- Review the proposal with multiple focused reviewer perspectives before any automated creation.
- Keep decomposition scheduling independent from implementation scheduling.
- Limit the first implementation to one active decomposition pipeline per project.

## Non-Goals

- A2O does not bundle static analysis, repository mining, or product-specific investigation tools.
- The MVP does not require parallel creation of multiple ticket trees.
- The MVP does not automatically implement generated child tickets.
- The MVP does not overload existing `Task.kind` values such as `single`, `parent`, or `child`.
- The MVP does not force decomposition through the existing `implementation` phase.

## Scheduling Boundary

Decomposition and implementation must be separate scheduler domains.

| Domain | Trigger | Work it owns | Concurrency |
| --- | --- | --- | --- |
| implementation | ordinary runnable A2O task state | implementation, review, verification, remediation, merge, parent review | existing implementation runtime policy |
| decomposition | `trigger:investigate` on a high-level ticket | investigate, author proposal, proposal review, optional gated child creation | one active pipeline per project in the MVP |

The important invariant is:

> An active implementation task must not prevent a `trigger:investigate` ticket from advancing, and an active decomposition pipeline must not prevent ordinary implementation tasks from advancing.

Domain routing is exclusive. A source ticket with `trigger:investigate` is owned by the decomposition domain and must be excluded from ordinary implementation runnable selection until the decomposition gate explicitly changes its labels or state. Only child tickets created or approved for implementation, such as tickets marked with `trigger:auto-implement`, may enter the implementation scheduler domain.

The two domains may share the kanban adapter, project package, repo slots, and evidence store, but they need separate runnable queues and separate active-run locks. Implementation `max_steps`, phase state, and worker occupancy must not be reused as the gate for decomposition. Decomposition `max_steps` or proposal review state must likewise not gate implementation selection.

Ticket creation itself does not need parallel execution in the MVP. Keeping a single decomposition pipeline avoids duplicate child tickets, lowers review cost, and makes idempotency simpler while still allowing implementation work to continue.

## Runtime Flow

```mermaid
flowchart TD
  Source["Requirement ticket\nlabel: trigger:investigate"]
  DecompScheduler["Decomposition scheduler domain"]
  Investigate["Investigate\nproject command"]
  Author["Author proposal\nAI ticket tree draft"]
  Review["Review panel\nfocused reviewers"]
  Gate{"Proposal accepted?"}
  Human["Human approval / blocked feedback"]
  Create["Create child tickets\nfuture gated step"]
  Implement["Implementation scheduler domain\ntrigger:auto-implement children"]

  Source --> DecompScheduler
  DecompScheduler --> Investigate
  Investigate --> Author
  Author --> Review
  Review --> Gate
  Gate -- no --> Human
  Gate -- yes --> Create
  Create --> Implement
```

The MVP can stop at a reviewed proposal. Automated child-ticket creation is a follow-up step behind an explicit gate until the proposal format, review result, and duplicate-prevention behavior are proven.

## Investigation Command Contract

Investigation is project-owned. A2O provides the lifecycle, request, result validation, evidence retention, and kanban updates.

The project package should declare a command such as:

```yaml
runtime:
  decomposition:
    investigate:
      command: ["./commands/investigate.sh"]
    author:
      command: ["./commands/author-proposal.sh"]
```

The exact schema can evolve, but the public contract should follow the existing project-script style:

- A2O passes a JSON request path through an `A2O_*` environment variable.
- The command writes one JSON result to an `A2O_*` result path.
- Scripts read repo paths from declared slot paths instead of private runtime files.
- Investigation runs against an isolated read-only snapshot or disposable workspace, not the active implementation workspace.
- Investigation commands must not mutate repo slots, create implementation branches, or take locks that would block implementation runs.
- Non-zero exit or invalid JSON blocks the decomposition pipeline with evidence.

User-facing decomposition CLI actions must run project-owned commands through the host-agent command protocol when the project command needs host-only AI worker CLIs, credentials, or local agent configuration. See [77-host-agent-decomposition-command-protocol.md](77-host-agent-decomposition-command-protocol.md).

The request should include:

- source ticket ref, title, description, labels, and priority
- source ticket parent/child/blocker relations
- repo slot aliases and workspace paths
- project package metadata relevant to implementation and verification
- allowed repo labels and supported task kinds
- previous decomposition evidence for reruns, if present

The result should include:

- summary of the requirement and product context
- affected modules, files, commands, APIs, schemas, and external systems
- known dependencies and ordering constraints
- risk areas and confidence
- suggested ticket boundaries
- open questions that should block automatic creation
- evidence links or artifact paths

## Author Proposal Contract

The author step converts investigation evidence into a normalized proposal. It should not create tickets directly.

The author step follows the same project-script style as investigation: A2O writes an author request JSON path to `A2O_DECOMPOSITION_AUTHOR_REQUEST_PATH`, expects one proposal JSON object at `A2O_DECOMPOSITION_AUTHOR_RESULT_PATH`, runs in a disposable decomposition workspace, and records proposal evidence even when the author output is invalid.

The proposal should contain:

- source ticket ref and proposal fingerprint
- proposed parent update, if the source ticket should become the parent
- child ticket drafts with title, body, acceptance criteria, labels, priority, and verification level
- dependency graph between proposed children
- expected blocker relations
- expected parent/child relations
- suggested `trigger:auto-implement` usage
- stable boundary and rationale for each child draft
- unresolved questions and required human decisions

The proposal `outcome` defaults to `draft_children`. In that outcome, the proposal can also include optional generated-parent content:

```json
{
  "outcome": "draft_children",
  "parent": {
    "title": "Implementation plan title",
    "body": "Human-readable plan, design notes, child list, and overall acceptance criteria."
  },
  "children": []
}
```

If investigation shows the requested behavior already exists, the author can return `outcome: "no_action"`, `children: []`, and a non-empty `reason`. If the requirement cannot be decomposed safely, the author can return `outcome: "needs_clarification"`, `children: []`, a non-empty `reason`, and one or more `questions`. These outcomes still go through proposal review, but child creation does not create a generated parent or children.

The proposal may include optional `refactoring_assessment` using the same schema as worker results. A2O validates and stores this object but does not decide project-specific refactoring policy. The project package prompt, skill, or docs must define what counts as refactoring debt and whether it belongs in the current child set. `include_child` means the proposal should include a normal child draft for the refactoring work. `defer_follow_up` does not block child creation; A2O records the debt in proposal evidence, source-ticket comments, and generated-parent content so parent review can decide whether to create a follow-up child. `blocked_by_design_debt` and `needs_clarification` must be distinguishable from ordinary technical blocked states.

The proposal fingerprint is required for idempotency. It should be derived from the source ticket ref, source revision fields, investigation result digest, and ordered child draft content.

Each child draft also needs a stable child idempotency key derived from the source ticket ref and the child boundary, not from volatile title text alone. Creation uses the proposal fingerprint to identify the proposal version and child keys to reconcile individual tickets.

## Review Panel

The MVP review panel may run reviewers sequentially. The key design point is independent reviewer responsibility, not parallel execution.

Recommended reviewer scopes:

- architecture reviewer: checks boundaries, repo labels, and dependency direction
- planning reviewer: checks child granularity, blocker graph, and implementation order
- verification reviewer: checks acceptance criteria and deterministic validation expectations

Any critical finding blocks automatic child creation. Findings are stored with the proposal evidence and posted back to the source ticket. A clean review means the proposal is eligible for the next configured gate; it does not imply implementation should start without created child tickets.

## Kanban Creation Boundary

Automated creation should be a later gated step after proposal-only mode is stable.

When enabled, creation must use the kanban adapter boundary rather than provider-specific calls scattered through orchestration code. It should reuse or generalize the current child-ticket writer behavior so multiline descriptions, labels, parent relations, blocker relations, and comments follow the existing command contract.

Creation must be idempotent:

- store the proposal fingerprint on the source ticket evidence or comment
- store a stable child idempotency key on each created child ticket, relation comment, or evidence record
- detect already-created child tickets by child key even when a rerun changes the proposal fingerprint
- reconcile partial creation by completing missing children and relations before creating anything new
- avoid creating duplicates on rerun
- record created ticket refs, relation results, and failed writes

Generated implementation children should receive `trigger:auto-implement` only after the proposal gate allows them to enter the implementation scheduler domain.

## Evidence And Status

Decomposition runs should publish evidence separately from implementation runs.

Minimum evidence:

- investigation request and result
- author proposal
- reviewer findings and final disposition
- proposal fingerprint
- child creation result, when enabled
- blocked reason and next operator action

Runtime status and future watch-summary output should be able to show both domains. The normal implementation task tree should not need to pretend that decomposition is a child implementation task.

## Rollout Plan

1. Document the design, schema direction, and scheduler invariants.
2. Add proposal-only runtime support for `trigger:investigate`.
3. Add project-package validation for the investigation command declaration.
4. Add review-panel evidence and blocking disposition.
5. Add human-approved child-ticket creation.
6. Consider fully automated child creation only after duplicate prevention and review quality are proven.

## Validation Requirements

Future implementation should include tests for:

- implementation scheduler work does not block decomposition runnable selection
- decomposition active lock does not block implementation runnable selection
- only one decomposition pipeline can be active per project in the MVP
- invalid investigation output blocks with actionable evidence
- proposal review findings prevent child-ticket creation
- child-ticket creation is idempotent across reruns
- generated children keep parent, blocker, label, and `trigger:auto-implement` relations

The reference product suite should include one requirement ticket that decomposes into multiple implementation tickets with at least one explicit dependency.
