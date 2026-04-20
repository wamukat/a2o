# Parent-Child Task Flow

Use parent-child tasks when one product change spans multiple repo slots and each repo should be implemented as its own child task. A2O coordinates the child tasks, integration review, verification, merge, and evidence from the kanban relations.

The purpose of this workflow is to avoid turning a cross-repository change into one oversized task. Split implementation by repository, then use a parent task for the integrated review, verification, and final merge. If the work fits in one repository, read [20-project-package.md](20-project-package.md) and [30-operating-runtime.md](30-operating-runtime.md) instead.

## Package Setup

Declare each repository as its own repo slot in `project.yaml`.

```yaml
repos:
  repo_alpha:
    path: ../repos/catalog-service
    role: product
    label: repo:catalog
  repo_beta:
    path: ../repos/storefront
    role: product
    label: repo:storefront
runtime:
  phases:
    parent_review:
      skill: skills/review/parent.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    verification:
      commands:
        - "{{a2o_root_dir}}/reference-products/multi-repo-fixture/project-package/commands/verify-all.sh"
    merge:
      policy: ff_only
      target_ref:
        default: refs/heads/main
```

Repo labels come from `repos.<slot>.label`. A2O provisions its own required lanes and internal labels. Do not add synthetic aggregate labels that mean "all repos" or "both repos"; they only work for a two-repo mental model and do not scale to three or more repositories.

## Kanban Setup

Create one parent task in the runnable lane, normally `To do`.

Parent labels:

- `trigger:auto-parent`
- `repo:catalog`
- `repo:storefront`

Parent body:

```text
Coordinate a cross-repo catalog contract change.
The catalog-service child should expose an inactive field in the summary.
The storefront child should render that field in the summary output.
Verify both repositories before parent completion.
```

Create one child task per repo.

Catalog child labels:

- `trigger:auto-implement`
- `repo:catalog`

Storefront child labels:

- `trigger:auto-implement`
- `repo:storefront`

Relate the children to the parent before runtime execution.

```sh
python3 tools/kanban/cli.py task-relation-create \
  --project "A2OReferenceMultiRepo" \
  --task "<parent-ref>" \
  --other-task "<catalog-child-ref>" \
  --relation-kind subtask

python3 tools/kanban/cli.py task-relation-create \
  --project "A2OReferenceMultiRepo" \
  --task "<parent-ref>" \
  --other-task "<storefront-child-ref>" \
  --relation-kind subtask
```

A2O derives parent and child task kind from the `subtask` relation. Do not add `kind:*` labels.

## Runtime Flow

1. A2O selects runnable child tasks from the configured kanban lane.
2. Each child task runs implementation, review, verification, remediation if needed, and merge.
3. Child merge targets the parent integration branch.
4. After child work is complete, the parent task runs `parent_review`.
5. Parent verification runs against the integrated workspace.
6. Parent merge publishes to `runtime.phases.merge.target_ref`.

Users configure merge policy and the live target ref. Users do not configure `merge_to_parent` or `merge_to_live`; A2O derives child-to-parent and parent-to-live behavior from the parent-child topology.

## Inspecting Progress

Use the runtime summary to see the active phase and result.

```sh
a2o runtime watch-summary
a2o runtime describe-task <parent-ref>
a2o runtime describe-task <child-ref>
```

`describe-task` is the preferred way to correlate kanban comments, workspace evidence, phase results, and blocked diagnostics.

## Reference Package

The runnable reference package is `reference-products/multi-repo-fixture/project-package/`.

Start from:

- `project.yaml`
- `task-templates/003-parent-child-contract-task.md`
- `skills/review/parent.md`
- `commands/verify-all.sh`
