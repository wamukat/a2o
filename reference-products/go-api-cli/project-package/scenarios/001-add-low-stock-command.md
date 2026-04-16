# Scenario: Add low-stock CLI output

Create a single task with labels:

- `a2o:ready`
- `repo:app`
- `kind:single`

Task body:

Add a `low-stock` CLI command that prints SKUs needing reorder. Reuse `internal/inventory` and add tests for the selection behavior. Keep API behavior unchanged.
