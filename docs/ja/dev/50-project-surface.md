# A2O Project Surface

この文書は、project が所有する設定面を小さく保つためのもの。
project package は product 固有知識を表現するが、`project.yaml` を無制限な Engine 設定ファイルにしてはならない。

## 1. 目的

- project 固有の注入点を最小限に保つ。
- 過去の product 固有複雑性を Engine core へ持ち込まない。
- `project.yaml` を runtime 内部設定の寄せ集めではなく、明確な package config にする。
- task lifecycle、workspace topology、evidence、merge semantics は A2O が所有する。

## 2. Minimal Surface

Project package が設定してよいもの:

- implementation skill
- review skill
- parent review skill
- implementation / review executor commands
- verification commands
- remediation commands
- repo slots and labels
- A2O がサポートする範囲内の merge policy と live target ref

## 3. Core-Owned Behavior

Project package は次を再定義しない。

- task kind semantics
- phase semantics
- workspace topology
- rerun semantics
- evidence model
- scheduler behavior
- kanban provider implementation

## 4. Phase Commands

公開 schema は次の形を使う。

```yaml
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - your-ai-worker
          - "--schema"
          - "{{schema_path}}"
          - "--result"
          - "{{result_path}}"
```

A2O はこの command を内部 stdin-bundle protocol に展開する。
executor は worker result JSON を `{{result_path}}` に書き出す。

Stable script contract は [55-project-script-contract.md](55-project-script-contract.md) で定義する。Project scripts は private runtime metadata files ではなく、`A2O_*` worker environment names と `slot_paths` などの request fields を使う。

## 5. Verification And Remediation

Verification commands と remediation commands は project が所有する。
これらは materialized workspace で実行され、次の placeholders を使える。

- `{{workspace_root}}`
- `{{a2o_root_dir}}`
- `{{root_dir}}`

Remediation commands は、verification failure に対して deterministic な formatting や repair command がある場合に使う。

## 6. Merge

Merge は、project-owned policy と live target ref で設定する。実際の merge target は A2O が task topology から導出する。

```yaml
runtime:
  phases:
    merge:
      policy: ff_only
      target_ref: refs/heads/main
```

Project は policy と live target ref を選択できるが、`project.yaml` の中で `merge_to_live` や `merge_to_parent` は選択しない。

## 7. Presets

0.5.3 の公開 package format は単一ファイルの `project.yaml` である。
Internal presets は実装詳細として残りうるが、package author が追加の preset file を管理する必要はない。
