# プロジェクトパッケージ

プロジェクトパッケージは、A2O に「このプロダクトをどう扱えばよいか」を渡す入力である。A2O Engine はカンバンタスクを見つけ、ワークスペースを用意し、フェーズを進める。プロジェクトパッケージは、そのときに必要なプロダクト固有の設定、AI への指示、検証コマンド、タスクの型を渡す。

この文書は、パッケージに何を置き、それが A2O のどこで使われるかを説明する。`project.yaml` の全項目は [90-project-package-schema.md](90-project-package-schema.md) を参照する。

読む目的は、`project.yaml` を単なる設定ファイルではなく、A2O に渡すプロダクト仕様として理解することである。ここでは詳細なスキーマ暗記よりも、リポジトリ、スキル、コマンド、タスクテンプレートがランタイム中にどう使われるかを押さえる。

## 何を入力するか

プロジェクトパッケージは、次の 4 種類の入力を 1 つのディレクトリにまとめる。

| 入力 | 役割 | A2O が使うタイミング |
| --- | --- | --- |
| `project.yaml` | パッケージ名、カンバンプロジェクト、リポジトリスロット、フェーズ、実行コマンド、検証コマンドを定義する | 初期化、カンバン起動、ランタイム実行 |
| `skills/` | AI ワーカーに渡すプロダクト固有の判断基準を書く | 実装、レビュー、親タスクレビュー |
| `commands/` | ビルド、テスト、検証、修復、ワーカー用コマンドを置く | フェーズ実行、検証、修復 |
| `task-templates/` | 人間がカンバンタスクを作るときの型を置く | タスク作成時の参考 |

A2O はプロダクトの方針をソースコードから自動推測しない。リポジトリの境界、使うコマンド、AI に守らせるルール、検証方法はプロジェクトパッケージに明示する。

## 実行時のつながり

```mermaid
flowchart LR
  U@{ shape: rounded, label: "利用者" }
  P@{ shape: docs, label: "プロジェクトパッケージ" }
  K@{ shape: cyl, label: "カンバンタスク" }
  E@{ shape: rounded, label: "A2O Engine" }
  A@{ shape: rounded, label: "a2o-agent" }
  G@{ shape: cyl, label: "Git リポジトリ" }

  U -. "作成する" .-> P
  U -. "タスクを登録する" .-> K
  E -->|"project.yaml を読む"| P
  E -->|"タスクを選ぶ"| K
  E -->|"フェーズジョブを渡す"| A
  A -->|"スキル / コマンドを使う"| P
  A -->|"変更・検証する"| G
  E -->|"結果を記録する"| K
```

利用者が管理するものはプロジェクトパッケージとカンバンタスクである。A2O Engine は `project.yaml` を読んで、どのカンバンを見るか、どのリポジトリを扱うか、各フェーズで何を実行するかを決める。a2o-agent は Engine から渡されたジョブを実行し、パッケージ内のスキルとコマンドを使って Git リポジトリを変更・検証する。

## 推奨レイアウト

```text
project-package/
  README.md
  project.yaml
  commands/
  skills/
    implementation/
    review/
  task-templates/
  tests/
    fixtures/
```

`project.yaml` は唯一の公開パッケージ設定である。`manifest.yml` や `kanban/bootstrap.json` のような別設定ファイルを利用者に管理させない。

`commands/` には、ランタイムフェーズから呼ばれてよいプロジェクト管理のスクリプトを置く。本番用コマンドとテスト用フィクスチャは混ぜない。

`skills/` には AI ワーカーに渡すルールを置く。スキルは短く、具体的に書く。リポジトリの境界、編集してよいパス、レビュー観点、残すべき証跡など、AI が安全に推測できない判断を明記する。

`task-templates/` には人間がタスクを作るときのテンプレートを置く。A2O はテンプレートを自動投入しない。実行対象はカンバンに登録されたタスクである。

`tests/fixtures/` にはパッケージ検証用のフィクスチャや、結果が決まっているテスト用ワーカーを置く。通常運用のランタイムフェーズからフィクスチャを呼ばない。

## project.yaml の役割

`project.yaml` は、A2O がランタイムインスタンスを作り、タスクを選び、フェーズを実行するための入口である。

```yaml
schema_version: 1

package:
  name: my-product

kanban:
  project: MyProduct
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
  agent_control_plane_connect_timeout: 5s
  agent_control_plane_request_timeout: 30s
  agent_control_plane_retry_count: 2
  agent_control_plane_retry_delay: 1s
  review_gate:
    child: false
    single: false
    skip_labels: []
    require_labels: []
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

各 section の考え方は次の通りである。

| section | 利用者が決めること | A2O がそれを使う場所 |
| --- | --- | --- |
| `package` | パッケージの識別子 | ブランチ / 参照、ワークスペース、診断 |
| `kanban` | 対象プロジェクトとタスク選択 | タスクの取得、ボードの準備 |
| `repos` | リポジトリスロット、パス、カンバンラベル | ワークスペース準備、リポジトリ単位のタスク |
| `agent` | ホスト側に必要なコマンド | エージェント配置、事前診断 |
| `runtime.phases` | フェーズごとのスキル、実行コマンド、検証コマンド | 実装、レビュー、検証、修復、マージ |

A2O が管理するレーンや内部ラベルは書かない。`a2o kanban up` が必要なレーンと内部ラベルを用意する。

## スキルの書き方

スキルは AI ワーカーに渡すプロダクト固有の指示である。一般論ではなく、このプロダクトで守るべき判断を書く。

実装用スキルに書くこと:

- 変更してよいリポジトリとパス
- コーディングルール
- 実装後に必要な検証
- タスクコメントや証跡に残すべき情報
- プロジェクト固有の知識検索コマンドを使う条件

レビュー用スキルに書くこと:

- 指摘事項とみなす条件
- 公開 API、SPI、互換性、ドキュメントの確認観点
- 必須の検証証跡
- 残リスクの書き方

親タスクレビュー用スキルに書くこと:

- 子タスクの成果をどう統合して見るか
- 複数リポジトリ統合の確認観点
- マージ前に必要な証跡

スキルは、運用チームが実際に保守できる言語で書く。日本語で運用するプロダクトなら日本語でよい。

## コマンドの書き方

コマンドは、A2O がフェーズ中に呼ぶプロダクト管理の実行ファイルである。A2O の内部ファイルではなく、公開されているプレースホルダーと環境変数を使う。

ワーカーコマンドは要求データ一式を標準入力で受け取り、結果 JSON を `{{result_path}}` に書く。

通常のワーカー雛形は次のように生成する。

```sh
a2o worker scaffold --language python --output ./project-package/commands/a2o-worker.py
```

外部 AI や任意の worker command へ実装を委譲するプロジェクトでは、`project.yaml` から直接呼ばず、A2O の標準入力バンドル契約を保つラッパー雛形を生成する。

```sh
a2o worker scaffold --language command --output ./project-package/commands/a2o-command-worker
```

生成されたラッパーは `A2O_WORKER_COMMAND` に設定したコマンドへ A2O stdin bundle を渡す。そのコマンドは最終的な A2O worker result JSON を stdout に出す必要がある。ラッパーは A2O の結果契約を維持し、implementation 成功時に `review_disposition` がない結果を拒否する。

custom worker を開発する場合は、保存した worker request / result の組を使って、runtime 実行前に結果形式を検証する。

```sh
a2o worker validate-result --request request.json --result result.json
```

検証では、必須キーの不足、型エラー、`task_ref` / `run_ref` / `phase` の不一致を具体的に報告する。executor が review disposition の slot scope を設定している場合は、同じ公開値を `--review-slot-scope SCOPE` の繰り返しで渡す。`review_disposition` の scope は `slot_scopes` が正規キーであり、`repo_scope` は受け付けない。

要求されたプロダクト仕様が曖昧、または既存契約と矛盾して安全に続行できない場合、worker は技術的な `blocked` ではなく `clarification_request` を返す。

```json
{
  "success": false,
  "summary": "Requirement conflicts with the current permission model.",
  "rework_required": false,
  "clarification_request": {
    "question": "Should admin approval be required for this bypass?",
    "context": "The ticket asks for a bypass, but the current permission model requires explicit approval.",
    "options": ["Require admin approval", "Keep the current model"],
    "recommended_option": "Require admin approval",
    "impact": "A2O pauses scheduling for this task until the requester answers."
  }
}
```

`clarification_request` は依頼者入力待ちだけに使う。ランタイム失敗、不正な worker output、検証失敗、merge conflict、認証不足などは `failing_command` / `observed_state` を含む技術的失敗として返し、`blocked` 診断にする。

`runtime.review_gate.child` と `runtime.review_gate.single` は任意設定であり、既定は `false` である。既定では従来通り child / single タスクは implementation から verification へ進む。`true` にすると、その task kind の implementation 成功後に review フェーズを必ず通し、レビュー承認後に verification へ進む。レビュー指摘がある場合は implementation へ戻せる。

`runtime.review_gate.skip_labels` と `runtime.review_gate.require_labels` は、カンバンタスクのラベルで task kind の既定値を上書きする任意設定である。`require_labels` に一致するラベルがあれば review gate を有効にし、`skip_labels` に一致するラベルがあれば review gate を無効にする。両方に一致した場合は `skip_labels` を優先する。

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

検証コマンドはタスク結果を証明する。修復コマンドは再検証の前に、整形や生成ファイル更新など、プロジェクトが認めた保守的な修復だけを行う。

良いコマンドの条件:

- 同じ入力なら同じ結果になる
- 失敗理由と対象リポジトリ / パスが分かる
- 隠れたグローバル依存を避ける
- commit、push、カンバン状態の編集をしない
- 非公開の `.a3` メタデータや生成されたランチャーファイルを読まない

コマンドがタスク種別やリポジトリスロットによって変わる場合だけ、`project.yaml` の variants を使う。単純なパッケージでは既定のコマンドを優先する。

## 任意のメトリクス収集

プロジェクトは、検証成功後にだけ動く任意のメトリクス収集コマンドを追加できる。これは軽量な運用レポート用であり、検証が成功したかどうかの判定には影響しない。

```yaml
runtime:
  phases:
    metrics:
      commands:
        - app/project-package/commands/collect-metrics.sh
```

このコマンドは準備済みワークスペースで実行され、ワーカー要求には `command_intent=metrics_collection` が入る。コマンドは JSON オブジェクトを 1 つ stdout に出す。A2O は `task_ref`、`parent_ref`、`timestamp` を所有し、プロジェクトは次のセクションを返せる。

- `code_changes`
- `tests`
- `coverage`
- `timing`
- `cost`
- `custom`

未対応のトップレベルセクションや、オブジェクトではないセクション値は、メトリクス収集診断として記録される。成功済みの検証を失敗にはしない。

レポートにはランタイムのメトリクス export を使う。

```sh
a2o runtime metrics list --format json
a2o runtime metrics list --format csv
a2o runtime metrics summary
a2o runtime metrics summary --group-by parent --format json
a2o runtime metrics trends --group-by parent --format json
```

Grafana、表計算ソフト、BI ツールは、これらの export またはその下流コピーを読む。初期のメトリクス実装では、これらはランタイムの必須依存ではない。

## 通知 hook

プロジェクトは `runtime.notifications` に通知 hook を追加できる。A2O は phase 遷移が確定して保存された後、対象イベントに一致するコマンドを実行し、`A2O_NOTIFICATION_EVENT_PATH` にイベント payload の JSON パスを渡す。

```yaml
runtime:
  notifications:
    failure_policy: best_effort
    hooks:
      - event: task.blocked
        command: [app/project-package/commands/notify.sh]
      - event: task.completed
        command: [app/project-package/commands/notify.sh]
```

A2O が所有するのは hook の発火タイミングと payload 形状だけである。Slack、Discord、GitHub comment、email、社内通知などの通知先は project package が所有する。A2O core には通知先固有の処理を入れない。

初期実装で発火する phase 完了系イベントは次の通り。

- `task.phase_completed`
- `task.blocked`
- `task.needs_clarification`
- `task.completed`
- `task.reworked`
- `parent.follow_up_child_created`

`failure_policy` の既定値は `best_effort` で、hook が失敗してもタスク進行は変えず、失敗内容だけを記録する。`blocking` は同じ診断を記録したうえで、保存済み状態を見えるようにした後、runtime command を失敗させる。hook の stdout、stderr、exit status、実行時間、command、payload path は最新 phase execution diagnostics の `notification_hooks` に保存される。

## タスクテンプレートの位置づけ

タスクテンプレートは、人間がカンバンタスクを作るときの入力例である。ランタイムがタスクテンプレートを読んで自動実行するわけではない。

テンプレートには、A2O がタスクを正しく解釈するための情報を含める。

- 目的
- 対象リポジトリラベル
- 期待する変更
- 完了条件
- 検証観点
- 制約や触ってはいけない範囲

複数リポジトリの親タスクでは、対象リポジトリラベルをすべてタスクに付ける。`all` や `both` のような合成ラベルではなく、実際のリポジトリスロットに対応するラベルを使う。

## 通常設定とテスト用フィクスチャを分ける

`project.yaml` は通常運用用に保つ。本番運用の実装 / レビューフェーズから、結果が決まっているテスト用ワーカーを呼ばない。

パッケージが検証用プロファイルを必要とする場合は、明示的に分ける。

- `project-test.yaml` のような別設定を使う。
- フィクスチャ用ワーカーは `tests/fixtures/` 配下に置く。
- フィクスチャ用コマンドは本番用コマンドと間違えない名前にする。
- 検証用プロファイルの実行方法をドキュメントに書く。

別プロファイルは、使うときに明示する。

```sh
a2o project validate --package ./project-package --config project-test.yaml
a2o runtime run-once --project-config project-test.yaml
```

## 作成と確認

新規パッケージはテンプレートから始める。

```sh
a2o project template \
  --package-name my-product \
  --kanban-project MyProduct \
  --language node \
  --executor-bin your-ai-worker \
  --with-skills \
  --output ./project-package/project.yaml
```

生成後に `your-ai-worker`、検証コマンド、スキルの中身をプロダクトに合わせて変更する。

パッケージをランタイムに使う前に確認する。

```sh
a2o project lint --package ./project-package
```

`blocked` の指摘は実行前に直す。スキーマの詳細、プレースホルダー、variants の細かな仕様は [90-project-package-schema.md](90-project-package-schema.md) を参照する。

## レビュー観点

実際のタスクに使う前に、次を確認する。

- `project.yaml` が唯一の公開設定ファイルになっている。
- `a2o project lint --package ./project-package` に `blocked` の指摘がない。
- A2O が管理するレーンと内部ラベルを手書きしていない。
- `agent.required_bins` にプロダクトのツールチェーンとワーカー実行ファイルが含まれている。
- 本番運用のフェーズが `tests/fixtures/` を呼んでいない。
- 検証コマンドが失敗理由と対象範囲を出す。
- 修復コマンドが広範な予期しない変更を起こさない。
- スキルにリポジトリ境界、レビュー基準、必要な証跡が書かれている。
- 生成ファイルが `.work/a2o/` 配下に閉じている。
- 利用者向けドキュメントとコマンドが A2O 名を使っている。
