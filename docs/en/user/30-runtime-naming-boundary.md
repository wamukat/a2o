# Runtime Naming Boundary

A2O stands for Agentic AI Orchestrator and is the public product name. A3 is an internal compatibility name that may still appear in implementation code paths, state paths, and Engine CLI surfaces.

## Public Names

Use these names in user-facing docs and commands:

- `A2O`
- `a2o`
- `a2o-agent`
- `share/a2o`
- `.work/a2o/agent`
- `refs/heads/a2o/...`
- `reference-products`

## Internal Compatibility Names

These names may remain in implementation details:

- `A3`
- `a3`
- `bin/a3`
- `.a3`
- `A3_*` environment variables
- compatibility `refs/heads/a3/...`

Do not require users to author these names in normal setup docs. If they appear in diagnostics or internal implementation docs, describe them as compatibility surfaces.

## Naming Rules

- New public docs use A2O names.
- New project packages use A2O names.
- New CLI affordances should prefer `a2o`.
- Internal Ruby Engine APIs may keep A3 names where they are not part of the public user surface.
- Compatibility aliases must not become the documented primary path.

## User-Facing Runtime

User-facing runtime execution should use:

- `a2o runtime run-once`
- `a2o runtime loop`
- `a2o runtime start`

Internal Engine CLI examples must stay out of normal user setup docs.
