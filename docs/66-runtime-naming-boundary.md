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
- `.work/a2o-agent`
- `reference-products`

## Internal Compatibility Names

These names may remain in implementation details:

- `A3`
- `a3`
- `bin/a3`
- `.a3`
- `A3_*` environment variables
- `refs/heads/a3/...`

Do not require users to author these names in normal setup docs. If they appear in diagnostics or baseline reproduction notes, describe them as internal compatibility surfaces.

## Naming Rule

- New public docs use A2O names.
- New project packages use A2O names.
- New CLI affordances should prefer `a2o`.
- Existing internal Ruby Engine APIs may keep A3 names until a focused rename ticket changes them.
- Compatibility aliases must not become the documented primary path.

## Known Gap

User-facing runtime execution should use `a2o runtime run-once` or `a2o runtime loop`. If internal Engine CLI examples are needed for baseline reproduction, keep them in internal-context docs and do not make them the normal user path.
