# 親子タスクの流れ

この文書は、複数リポジトリにまたがる作業を子タスクと親タスクに分け、最後に統合レビュー / 検証 / マージする流れを説明する。

1 つのプロダクト変更が複数のリポジトリスロットにまたがり、リポジトリごとに子タスクとして実装したい場合は親子タスクを使う。A2O はカンバン上の関連をもとに、子タスク、統合レビュー、検証、マージ、証跡を連携させる。

## パッケージ設定

`project.yaml` ではリポジトリごとにリポジトリスロットを宣言する。

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

リポジトリラベルは `repos.<slot>.label` で定義する。A2O が必要とするレーンと内部ラベルは A2O が用意する。「全リポジトリ」や「両方」を意味する合成ラベルは使わない。2 リポジトリ前提の表現になり、3 リポジトリ以上に広がったときに意味が崩れる。

## カンバン設定

親タスクを実行対象のレーン、通常は `To do` に 1 つ作成する。

親タスクのラベル:

- `trigger:auto-parent`
- `repo:catalog`
- `repo:storefront`

親タスクの本文:

```text
複数リポジトリにまたがるカタログ契約変更をまとめる。
catalog-service 側の子タスクでは、summary に inactive フィールドを公開する。
storefront 側の子タスクでは、そのフィールドを summary 出力に表示する。
親タスクの完了前に両方のリポジトリを検証する。
```

リポジトリごとに子タスクを作成する。

Catalog 側の子タスクラベル:

- `trigger:auto-implement`
- `repo:catalog`

Storefront 側の子タスクラベル:

- `trigger:auto-implement`
- `repo:storefront`

ランタイム実行前に、子タスクを親タスクの subtask として関連づける。

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

A2O は `subtask` の関連から親 / 子のタスク種別を判断する。`kind:*` ラベルは追加しない。

## ランタイムの流れ

1. A2O は設定されたカンバンレーンから実行可能な子タスクを選択する。
2. 各子タスクは実装、レビュー、検証、必要に応じた修復、マージを実行する。
3. 子タスクのマージは親タスクの統合ブランチを対象にする。
4. 子タスクの作業が完了すると、親タスクで `parent_review` を実行する。
5. 親タスクの検証は、統合済みワークスペースに対して実行する。
6. 親タスクのマージは `runtime.phases.merge.target_ref` に反映する。

利用者が設定するのはマージ方針と本流のターゲット参照である。`merge_to_parent` や `merge_to_live` は利用者が設定しない。A2O は親子タスクの構造から、子タスクから親タスクへのマージと、親タスクから本流へのマージを導出する。

## 進行状況の確認

進行状況はランタイムの要約で確認する。

```sh
a2o runtime watch-summary
a2o runtime describe-task <parent-ref>
a2o runtime describe-task <child-ref>
```

カンバンコメント、ワークスペースの証跡、フェーズ結果、ブロック時の診断を対応づけて見る場合は `describe-task` を使う。

## 参照用パッケージ

実行可能な参照用パッケージは `reference-products/multi-repo-fixture/project-package/` にある。

まず次を見る。

- `project.yaml`
- `task-templates/003-parent-child-contract-task.md`
- `skills/review/parent.md`
- `commands/verify-all.sh`
