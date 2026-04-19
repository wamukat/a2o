# Scenario: Add work-order filtering

Create a single task with labels:

- `trigger:auto-implement`
- `repo:app`

Task body:

Add a domain function that filters work orders by status. Expose it from the API with a `/work-orders?status=queued` query path and add a Web summary line for queued work. Preserve existing summary behavior and tests.
