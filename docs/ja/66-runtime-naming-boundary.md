# Runtime Naming Boundary

対象読者: A2O 利用者 / runtime 実装者 / operator
文書種別: naming policy

A2O is the public product name. A3 remains an internal compatibility name in code paths, state paths, and Engine CLI surfaces that have not been renamed.

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
- legacy `refs/heads/a3/...`

Do not require users to author these names in normal setup docs. If they appear in diagnostics or internal implementation docs, describe them as compatibility surfaces.

## Naming Rule

- New public docs use A2O names.
- New project packages use A2O names.
- New CLI affordances should prefer `a2o`.
- Existing internal Ruby Engine APIs may keep A3 names until a focused rename ticket changes them.
- Compatibility aliases must not become the documented primary path.

## Known Gap

User-facing runtime execution should use `a2o runtime run-once`, `a2o runtime loop`, or `a2o runtime start`. Internal Engine CLI examples must stay out of normal user setup docs.
