# Scenario: Parent-child contract task

Create one parent task with labels:

- `trigger:auto-parent`
- `repo:catalog`
- `repo:storefront`

Parent task body:

Coordinate a cross-repo catalog contract change. The catalog-service child should expose an `inactive` field in the summary. The storefront child should render that field in the summary output. Verify both repositories before parent completion.

Create two child tasks and relate them to the parent before starting the flow:

- Catalog child labels: `trigger:auto-implement`, `repo:catalog`
- Storefront child labels: `trigger:auto-implement`, `repo:storefront`

Relation setup:

```sh
python3 tools/kanban/cli.py task-relation-create --project "A2OReferenceMultiRepo" --task "<parent-ref>" --other-task "<catalog-child-ref>" --relation-kind subtask
python3 tools/kanban/cli.py task-relation-create --project "A2OReferenceMultiRepo" --task "<parent-ref>" --other-task "<storefront-child-ref>" --relation-kind subtask
```

A2O derives parent and child task kind from these relations, not from `kind:*` labels.

Do not use an aggregate label that means "both repos". A parent task should carry every affected repo label so the same rule works for two or more repositories.
