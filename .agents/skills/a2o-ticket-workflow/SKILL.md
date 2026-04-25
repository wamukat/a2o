---
name: a2o-ticket-workflow
description: "A2O kanban ticket workflow. Use when handling A2O PJ tickets or A2O project work: manually solve the ticket, commit at self-complete, move to In review, record commits on the ticket, run sub-agent review loops, and move to Done only after review has no findings."
---

# A2O Ticket Workflow

Use this skill whenever the user asks to handle an A2O PJ / A2O kanban ticket or asks to execute A2O project work.

## Core Rule

Do not delegate the ticket to A2O runtime automation such as `a2o runtime run-once`. Read the ticket, understand the requested change, edit the repository yourself, and verify the result.

## Workflow

1. Find the target ticket on the A2O kanban board.
   - If no ticket is specified, inspect A2O board `To do` / `In progress` tickets and pick the highest-priority actionable ticket.
   - Read the ticket body, comments, relations, and relevant repository context before editing.

2. Start work.
   - Move the ticket to `In progress`.
   - Add a short kanban comment saying work started and what scope you are taking.

3. Implement and verify.
   - Make the smallest coherent code/docs changes that satisfy the ticket.
   - Run focused tests first, then broader verification when the blast radius warrants it.
   - Do not move to review until you believe the ticket is complete.

4. Commit at self-complete.
   - Create a git commit when you believe the implementation is complete.
   - Include the ticket ref in the commit message, for example `A2O#248 Hide SoloBoard behind kanban abstraction`.
   - If the Kanbalone ticket is linked to an external GitHub issue, add a commit-message footer so GitHub can link the commit back to the issue:
     - Same repository: `Refs: #123`
     - Different repository: `Refs: owner/repo#123`
     - Use `Refs`, not `Fixes`, `Closes`, or `Resolves`, unless the user explicitly wants the external issue closed by the commit/merge.
     - If one commit covers multiple linked external issues, include one `Refs:` footer per issue.
   - Move the ticket to `In review`.
   - Add a kanban comment with the commit SHA and verification performed.

5. Run review loop.
   - Ask a sub-agent to review the committed diff for correctness, regressions, missing tests, and incomplete ticket coverage.
   - The user's standing project rule is that A2O work must always go through sub-agent review. Do not stop to ask for additional permission before spawning the reviewer for an A2O ticket.
   - If the review reports findings, fix them, run relevant verification, commit the fix, update the ticket with the new commit SHA, and request another sub-agent review.
   - Repeat until the review reports no findings.

6. Finish.
   - When the latest review has no findings, add a final kanban comment with the reviewed commit SHA(s), tests, and review result.
   - Do not wait for an extra user confirmation after a sub-agent review returns `no findings`; move the ticket to `Done` unless the user explicitly asks to hold it.
   - Move the ticket to `Done`.

## Notes

- Keep internal implementation names such as service names and provider names when they are part of compatibility or diagnostic surfaces.
- Keep user-facing A2O surfaces aligned with the ticket wording.
- If the repository lacks a named Taskfile command from the ticket acceptance criteria, run the closest implemented equivalent and record that substitution in the kanban comment.
- When the user asks to create and proceed with several closely related follow-up tickets, create each ticket first, then prefer one coherent implementation only when the code paths and verification are shared. Still record per-ticket start scope, commit SHA, verification, and review outcome on every ticket.
- If a ticket flow itself reveals reusable operating guidance, update this repo-local skill before the final report. Keep the update procedural and small; do not add project-specific implementation details that will not generalize.
