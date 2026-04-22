# プロジェクトパッケージスキーマのリファレンス

この文書は `project.yaml` の詳細リファレンスである。導入時の考え方は先に [20-project-package.md](20-project-package.md) を読む。

この文書は、設定値を追加・変更するときに参照する。先に [20-project-package.md](20-project-package.md) で「なぜその設定が必要か」を理解し、この文書では実際の YAML 形、既定の責務境界、使えるプレースホルダーを確認する。

## 方針

プロジェクトパッケージ設定の正規ファイル名は `project.yaml` とする。

ランタイムの責務は `project.yaml` の明示的なランタイムセクションに置く。公開パッケージの設定ファイルは 1 本にまとめ、パッケージ作成者がプロジェクト設定とランタイム定義の責務分担で迷わない形にする。

作成時の判断と責務境界は [20-project-package.md](20-project-package.md) を参照する。

パッケージスキーマは次のルールに従う。

- `project.yaml` を正規ファイル名とする。
- 公開パッケージ設定は `project.yaml` だけを使う。
- 利用者向けのスキーマと診断では A2O 名を使う。A3 名は内部互換の詳細としてだけ残してよい。
- `a2o:follow-up-child` のような内部 follow-up ラベルは、通常の利用者作成スキーマへ露出しない。

## スキーマの形

```yaml
schema_version: 1

package:
  name: a2o-reference-typescript-api-web

kanban:
  project: A2OReferenceTypeScript
  selection:
    status: To do

repos:
  app:
    path: ..
    role: product
    label: repo:app

agent:
  workspace_root: .work/a2o/agent/workspaces
  required_bins:
    - git
    - node
    - npm
    - your-ai-worker

runtime:
  max_steps: 20
  agent_attempts: 200
  agent_poll_interval: 1s
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
    review:
      skill: skills/review/default.md
      executor:
        command:
          - your-ai-worker
          - "--schema"
          - "{{schema_path}}"
          - "--result"
          - "{{result_path}}"
    verification:
      commands:
        - app/project-package/commands/verify.sh
    remediation:
      commands:
        - app/project-package/commands/format.sh
    merge:
      policy: ff_only
      target_ref: refs/heads/main

task_templates:
  - path: task-templates/001-add-work-order-filter.md
```

ホスト側のエージェントバイナリは正規パス `.work/a2o/agent/bin/a2o-agent` に置く。導入時は `a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent` を使う。

## 各セクションの責務

`schema_version` は必須である。Version `1` は最初の単一ファイルスキーマを表す。未対応 version は、分かりやすいエラーで拒否する。

`package` はプロダクトのリポジトリではなく、パッケージを識別する。`package.name` は安定したパッケージ識別子であり、ファイルシステムとブランチ参照で安全に使える名前にする。

`kanban` はボード名、プロジェクトが所有するラベル、タスク選択条件を持つ。カンバンのバックエンドは A2O ランタイム配布物によって固定されており、作成者向けの `project.yaml` 設定ではない。A2O が管理するレーンと内部調整ラベルはランタイム実装の詳細であり、通常のパッケージスキーマには書かせない。

複数リポジトリの親タスクには、対象リポジトリラベルをすべて付ける。「全リポジトリ」や「両方」を意味する合成ラベルは作らない。合成ラベルは 2 リポジトリを超える構成に拡張できず、リポジトリスロットと直接対応しない。

`repos` は安定したリポジトリスロットを定義する。スロットキーはランタイム上の識別子である。`path` は絶対パスでない限り、パッケージディレクトリからの相対パスとする。`label` はカンバンラベルとリポジトリスロットを対応づける。省略時、実装処理は `repo:<slot>` を導出してよい。

`agent` はホスト側ワークスペース、プロダクトのツールチェーン要件、実行コマンド要件を持つ。`required_bins` は、エージェントが作業開始前に前提条件を検証できるよう宣言的に残す。

`runtime` は実行時の既定値とフェーズ定義を持つ。

`runtime.phases` はフェーズごとのスキル、実行コマンド、検証 / 修復コマンド、マージ方針を持つ。A2O はフェーズごとの実行コマンドを内部の標準入力バンドル用ランチャー設定へ変換する。利用者は別途 `launcher.json` を作らない。

フェーズ実行コマンドはワーカーバンドルを標準入力で受け取り、ワーカー結果 JSON を `{{result_path}}` に書く必要がある。実行コマンド用プレースホルダーには `{{result_path}}`、`{{schema_path}}`、`{{workspace_root}}`、`{{a2o_root_dir}}`、`{{root_dir}}` が含まれる。検証コマンドと修復コマンドは `{{workspace_root}}`、`{{a2o_root_dir}}`、`{{root_dir}}` を使える。

プロジェクトコマンドは、ワーカー要求 JSON と `A2O_*` ワーカー環境変数を安定した契約として扱う。パッケージスクリプトから非公開の `.a2o/.a3` メタデータファイルや生成された `launcher.json` ファイルを読んではならない。
実装、レビュー、検証、修復のジョブはすべて `A2O_WORKER_REQUEST_PATH` を公開する。検証と修復の要求 JSON は `command_intent`、`slot_paths`、`scope_snapshot`、`phase_runtime` を含むため、対象リポジトリスロットや適用方針はこれらから判断する。
スロット単位の修復では、コマンドのカレントディレクトリがリポジトリスロットになる場合があるが、要求は準備済みワークスペース全体を表す。

検証コマンドと修復コマンドは、マージ設定と同じ `default` / `variants` 形式も使える。`task_kind`、`repo_scope`、フェーズによってコマンド方針が変わる場合だけ使う。

```yaml
runtime:
  phases:
    verification:
      commands:
        default:
          - app/project-package/commands/verify-all.sh
        variants:
          task_kind:
            parent:
              phase:
                verification:
                  - app/project-package/commands/verify-parent.sh
    remediation:
      commands:
        default:
          - app/project-package/commands/format-all.sh
        variants:
          task_kind:
            child:
              repo_scope:
                repo_beta:
                  phase:
                    verification:
                      - app/project-package/commands/format-repo-beta.sh
```

単純なリスト形式を既定とする。ヘルパーコードにタスク種別やリポジトリスロット方針が隠れてしまう場合だけ variants を使う。
`default` はトップレベル、`task_kind` 配下、`repo_scope` 配下に指定できる。より具体的に一致した値が優先される。

通常のパッケージでは実装フェーズとレビューフェーズを定義する。

```yaml
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    review:
      skill: skills/review/default.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
```

これは内部的に固定の標準入力バンドル用実行コマンドへ展開される。`prompt_transport`、`result`、`schema`、`default_profile` は A2O の実装詳細であり、有効な `project.yaml` 項目ではない。

新しいパッケージは実行コマンドブロックを手書きせず、生成テンプレートから始める。

```sh
a2o project template \
  --package-name my-product \
  --kanban-project MyProduct \
  --language node \
  --executor-bin your-ai-worker \
  --with-skills \
  --output ./project-package/project.yaml
```

テンプレートはフェーズ単位の実行コマンド形式を使う。`--language` は `agent.required_bins` を制御する。`--executor-bin` と繰り返し指定できる `--executor-arg` は、実装フェーズとレビューフェーズの実行コマンドを生成する。

`--output` がファイルを指す場合、生成器は `project.yaml` を書く。`--with-skills` を付けると、実装、レビュー、親タスクレビューの初期スキルも書き、生成した親タスク用スキルを参照する `parent_review` フェーズを追加する。カンバン初期化データは `kanban.project`、`kanban.labels`、`repos.<slot>.label` から導出される。A2O が管理するレーンと内部調整ラベルは `a2o kanban up` が用意する。

`project.yaml` は通常の本番運用プロファイルである。検証用プロファイルは `project-test.yaml` のような別ファイルにしてよいが、利用時は `a2o project validate --config project-test.yaml` または `a2o runtime run-once --project-config project-test.yaml` で明示的に選択する。

`runtime.phases.merge` はマージ方針と本流のターゲット参照を持つ。マージ先は A2O がタスク構造から導出するため、利用者は設定しない。

`task_templates` は検証と導入支援のための任意メタデータである。タスクテンプレートの項目は Markdown のタスクテンプレートを指す。ランタイムのタスク選択は引き続きカンバンから行う。タスクテンプレートは既定では自動登録されない。

## 参照用プロダクトの例

### TypeScript API / Web

```yaml
schema_version: 1
package:
  name: a2o-reference-typescript-api-web
kanban:
  project: A2OReferenceTypeScript
  selection:
    status: To do
repos:
  app:
    path: ..
    label: repo:app
    role: product
agent:
  required_bins: [git, node, npm, your-ai-worker]
runtime:
  max_steps: 20
  agent_attempts: 200
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    review:
      skill: skills/review/default.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    verification:
      commands:
        - app/project-package/commands/verify.sh
    remediation:
      commands:
        - app/project-package/commands/format.sh
    merge:
      policy: ff_only
      target_ref: refs/heads/main
```

### Go API / CLI

```yaml
schema_version: 1
package:
  name: a2o-reference-go-api-cli
kanban:
  project: A2OReferenceGo
  selection:
    status: To do
repos:
  app:
    path: ..
    label: repo:app
agent:
  required_bins: [git, go, your-ai-worker]
runtime:
  max_steps: 20
  agent_attempts: 200
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    review:
      skill: skills/review/default.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    verification:
      commands:
        - app/project-package/commands/verify.sh
    merge:
      policy: ff_only
      target_ref: refs/heads/main
```

### Python サービス

```yaml
schema_version: 1
package:
  name: a2o-reference-python-service
kanban:
  project: A2OReferencePython
  selection:
    status: To do
repos:
  app:
    path: ..
    label: repo:app
agent:
  required_bins: [git, python3, your-ai-worker]
runtime:
  max_steps: 20
  agent_attempts: 200
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    review:
      skill: skills/review/default.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    verification:
      commands:
        - app/project-package/commands/verify.sh
    merge:
      policy: ff_only
      target_ref: refs/heads/main
```

### 複数リポジトリのフィクスチャ

```yaml
schema_version: 1
package:
  name: a2o-reference-multi-repo
kanban:
  project: A2OReferenceMultiRepo
  selection:
    status: To do
repos:
  repo_alpha:
    path: ../repos/catalog-service
    role: product
    label: repo:catalog
  repo_beta:
    path: ../repos/storefront
    role: product
    label: repo:storefront
agent:
  required_bins: [git, node, your-ai-worker]
runtime:
  max_steps: 40
  agent_attempts: 300
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    review:
      skill: skills/review/default.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    parent_review:
      skill: skills/review/parent.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    verification:
      commands:
        - "{{a2o_root_dir}}/reference-products/multi-repo-fixture/project-package/commands/verify-all.sh"
    remediation:
      commands:
        - "{{a2o_root_dir}}/reference-products/multi-repo-fixture/project-package/commands/format.sh"
    merge:
      policy: ff_only
      target_ref:
        default: refs/heads/main
```

## 現在の契約

1. `project.yaml` のスキーマバージョン `1` が公開設定の契約である。
2. ランタイムブリッジは `runtime.phases` から内部ランタイム用のパッケージデータを導出する。
3. 参照用プロダクトパッケージは単一ファイルの `project.yaml` を使う。
4. パッケージ読み込みは、未対応の分割設定ファイルを拒否する。
5. パッケージスキーマ、ドキュメント、通常診断は A2O 向けの名前を使う。
