# A2O Engineering Rulebook

This document defines A2O's everyday engineering discipline. Design documents define what to build; this document defines how to build it.

Read it to align implementation decisions. A2O favors changes that keep ticket scope, tests, responsibility boundaries, and user-facing diagnostics coherent over changes that merely work in the short term. For design details, start at [00-design-map.md](00-design-map.md) and follow the relevant detail document.

## Runtime Placement

This rulebook applies when changing any part of A2O Engine, the host launcher, `a2o-agent`, project packages, or kanban adapters. The focused design documents describe specific runtime flows. This document sets the decision standard for changes, test additions, review, and protection of public / internal boundaries.

## Core Rules

- Prefer immutable domain objects.
- Use short Red -> Green -> Refactor loops.
- Add failing tests before changing behavior.
- Refactor when duplicated knowledge or unclear responsibility appears.
- Do not avoid necessary fixes only to make the current change look smaller.
- Keep product-specific behavior out of Engine core.

## Immutability

Domain objects are immutable by default. A state change should return a new object rather than mutate an existing one. Mutable state is acceptable only when it belongs to infrastructure or adapter responsibilities, and that boundary must stay explicit.

Core concepts such as task, run, and evidence must not accumulate ad hoc setters or hidden state changes.

## TDD

Use the smallest useful loop:

1. Write a failing test that captures the design pressure in code.
2. Add the smallest implementation that passes.
3. Refactor without changing behavior.

Skipping tests is acceptable only for purely mechanical changes or documentation-only changes. Shared behavior, public CLI behavior, runtime progression, workspace materialization, verification, merge, and diagnostics require tests.

## Refactoring

Refactoring is part of normal implementation, not a postponed cleanup phase. When the same knowledge appears in two places, review the ownership boundary early.

Do not add an abstraction only because future variation might appear. Add one when it reduces current complexity, removes meaningful duplication, or matches an established local pattern.

## Review Standard

Reviews should prioritize:

- behavioral regressions
- incomplete ticket coverage
- missing tests
- unclear public/internal surface boundaries
- product-specific assumptions in core code
- user-facing diagnostics that do not explain the next action

Documentation and tests are part of the release surface.

## Boundaries

Do not turn validation fixtures, temporary notes, or one product's operational workaround into a standard Engine concept. If external behavior must change, discuss the product impact before implementing.
