# Parent-Child Task Flow

1 つの product change が複数の repo slot にまたがり、repo ごとに child task として実装したい場合は parent-child task を使う。A2O は kanban relation をもとに、child task、integration review、verification、merge、evidence を連携させる。

## Package Setup

`project.yaml` では repository ごとに repo slot を宣言する。

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

Repo label は `repos.<slot>.label` で定義する。A2O が必要とする lane と internal label は A2O が用意する。「全 repo」や「両方」を意味する合成 label は使わない。2 repo 前提の表現になり、3 repo 以上に広がったときに意味が崩れる。

## Kanban Setup

Parent task を runnable lane、通常は `To do` に 1 つ作成する。

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

Repo ごとに child task を作成する。

Catalog child labels:

- `trigger:auto-implement`
- `repo:catalog`

Storefront child labels:

- `trigger:auto-implement`
- `repo:storefront`

Runtime 実行前に child を parent の subtask として関連づける。

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

A2O は `subtask` relation から parent / child の task kind を判断する。`kind:*` label は追加しない。

## Runtime Flow

1. A2O は設定された kanban lane から runnable な child task を選択する。
2. 各 child task は implementation、review、verification、必要に応じた remediation、merge を実行する。
3. Child merge は parent integration branch を target にする。
4. Child work が完了すると、parent task で `parent_review` を実行する。
5. Parent verification は integrated workspace に対して実行する。
6. Parent merge は `runtime.phases.merge.target_ref` に publish する。

利用者が設定するのは merge policy と live target ref である。`merge_to_parent` や `merge_to_live` は利用者が設定しない。A2O は parent-child topology から child-to-parent と parent-to-live の挙動を導出する。

## Inspecting Progress

進行状況は runtime summary で確認する。

```sh
a2o runtime watch-summary
a2o runtime describe-task <parent-ref>
a2o runtime describe-task <child-ref>
```

Kanban comment、workspace evidence、phase result、blocked diagnostics を対応づけて見る場合は `describe-task` を使う。

## Reference Package

実行可能な reference package は `reference-products/multi-repo-fixture/project-package/` にある。

まず次を見る。

- `project.yaml`
- `task-templates/003-parent-child-contract-task.md`
- `skills/review/parent.md`
- `commands/verify-all.sh`
