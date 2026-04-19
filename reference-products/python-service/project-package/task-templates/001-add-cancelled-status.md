# Scenario: Add cancelled appointment status

Create a single task with labels:

- `trigger:auto-implement`
- `repo:app`

Task body:

Extend appointment summaries to count `cancelled` appointments. Add tests for cancelled slots and expose the count from `/appointments`. Keep `next_open_slot` behavior unchanged.
