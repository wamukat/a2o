# A2O Engineering Rulebook

This document fixes the day-to-day engineering rules for A2O. Design documents define what to build; this document defines how to build it.

## Core Rules

- Prefer immutable domain objects.
- Use short Red -> Green -> Refactor loops.
- Add failing tests before changing behavior.
- Refactor when duplicated knowledge or unclear responsibility appears.
- Do not avoid necessary fixes only to keep the current change smaller.
- Keep product-specific behavior out of Engine core.

## Immutability

Domain objects are immutable by default. State changes should return new objects rather than mutating existing ones. Mutable state is acceptable only when it is an infrastructure or adapter concern, and that boundary must stay explicit.

Core concepts such as task, run, and evidence must not grow ad hoc setters or hidden mutation.

## TDD

Use the smallest useful loop:

1. Write a failing test that fixes the design pressure in code.
2. Add the smallest implementation that passes.
3. Refactor without changing behavior.

Skipping tests is acceptable only for truly mechanical or documentation-only changes. Shared behavior, public CLI behavior, runtime orchestration, workspace materialization, verification, merge, and diagnostics require tests.

## Refactoring

Refactoring should happen during normal implementation, not as a postponed cleanup phase. When the same knowledge appears twice, review the ownership boundary early.

Do not add abstraction only because future variation might appear. Add it when it removes current complexity, reduces meaningful duplication, or matches an established local pattern.

## Review Standard

Reviewers should prioritize:

- behavioral regressions
- incomplete ticket coverage
- missing tests
- unclear public/internal surface boundaries
- product-specific assumptions in core code
- user-facing diagnostics that do not explain the next action

Documentation and tests are part of the release surface.

## Boundaries

Do not turn validation fixtures, temporary notes, or one product's operational workaround into a standard Engine concept. If external behavior must change, discuss the product impact before implementing.
