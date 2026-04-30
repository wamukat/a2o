# クイックスタート

この文書は、A2O を初めて導入し、カンバンタスクを 1 つ A2O に処理させるまでの最短手順を説明する。全体像は先に [00-overview.md](00-overview.md) を読む。

この手順は「まず 1 件動かす」ためのものだ。プロジェクトパッケージを細かく設計する前に、ホスト用 `a2o`、カンバン、`a2o-agent`、ランタイムが同じインスタンスとしてつながる状態を作る。設定項目の意味で迷った場合は [20-project-package.md](20-project-package.md) に戻る。

## この手順で到達する状態

| 手順 | 達成すること |
|---|---|
| ホスト用ランチャーの導入 | ホストから `a2o` コマンドを実行できる |
| プロジェクトパッケージの作成 | A2O がプロダクトのリポジトリ、スキル、コマンド、カンバンボードを読める |
| ランタイムの初期化 | `.work/a2o/runtime-instance.json` にランタイムインスタンスを作る |
| カンバンの起動 | A2O 用ボード、レーン、内部ラベルを用意する |
| エージェントの配置 | プロダクト環境でジョブを実行する `a2o-agent` を配置する |
| タスクの取り込み | カンバンタスクを A2O が拾い、結果をボード / Git / 証跡に残す |

## 前提

- Docker が使える。
- プロダクトのリポジトリがある。
- A2O 用のプロジェクトパッケージをリポジトリルートに置ける。
- `a2o-agent` を実行する環境に、プロダクトのツールチェーンと AI 実行コマンドを用意できる。

実行コマンドは、実際にエージェント環境で実行できるバイナリに置き換える。テンプレートの `your-ai-worker` のままでは、`a2o doctor` またはランタイム実行で止まる。

## 1. ホスト用ランチャーを入れる

```sh
mkdir -p "$HOME/.local/bin" "$HOME/.local/share"

docker run --rm \
  -v "$HOME/.local:/install" \
  ghcr.io/wamukat/a2o-engine:0.5.57 \
  a2o host install \
    --output-dir /install/bin \
    --share-dir /install/share/a2o \
    --runtime-image ghcr.io/wamukat/a2o-engine:0.5.57

export PATH="$HOME/.local/bin:$PATH"
```

`a2o host install` は、ランタイムイメージからホスト用ランチャーと共有ランタイム資材を取り出す。ホストに Ruby ランタイムは要求しない。

`docker run ... a2o --help` はランタイムコンテナの入口で表示されるヘルプであり、ホスト用ランチャーの全コマンド一覧ではない。以後はインストール済みの `a2o` を使う。

## 2. プロジェクトパッケージを作る

ワークスペースルートに `project-package/` を置く。このクイックスタートでは、このディレクトリを標準のパッケージパスとして扱う。

```text
project-package/
  README.md
  project.yaml
  commands/
  skills/
  task-templates/
```

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

このコマンドは `project.yaml` と最初のスキルファイルを作る。作成後に `your-ai-worker` を実際の実行コマンドに置き換える。

パッケージの考え方は [20-project-package.md](20-project-package.md)、スキーマの詳細は [90-project-package-schema.md](90-project-package-schema.md) を読む。

## 3. パッケージを確認する

```sh
a2o project lint --package ./project-package
```

`project lint` は `project.yaml`、コマンドファイル、テスト用フィクスチャの参照、利用者向けの場所に漏れた内部名を確認する。`blocked` の指摘はランタイム実行前に直す。

検証用の別プロファイルを使う場合だけ、明示的に設定ファイルを指定して確認する。

```sh
a2o project validate --package ./project-package --config project-test.yaml
```

通常の `project.yaml` は、本番運用向けの設定として保つ。

## 4. ランタイムインスタンスを作る

```sh
a2o project bootstrap
```

`project bootstrap` は `.work/a2o/runtime-instance.json` を作る。以後の `kanban`、`agent`、`runtime` コマンドは、このインスタンス設定を見つけて同じランタイムインスタンスを使う。

ポート、Compose プロジェクト名、外部 Kanbalone ボードを使いたい場合だけオプションを指定する。

```sh
a2o project bootstrap --compose-project my-product --kanbalone-port 3471 --agent-port 7394
```

```sh
a2o project bootstrap --kanban-mode external --kanban-url http://127.0.0.1:3470
```

## 5. カンバンを起動する

```sh
a2o kanban up
a2o kanban url
```

`kanban up` は同梱されたカンバンサービスを起動し、A2O が必要とするレーンと内部ラベルを用意する。外部モードでは同梱サービスを起動せず、設定済み Kanbalone endpoint を検証してそのボードを初期化する。`kanban url` はボード URL を表示する。

同じ Compose プロジェクトなら既存ボードを再利用する。ボードが空に見える場合は、Compose プロジェクトや Docker volume が変わっていないか確認する。運用の詳細は [30-operating-runtime.md](30-operating-runtime.md) を読む。

## 6. エージェントを配置する

```sh
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
```

`a2o-agent` はプロダクト環境で実行コマンド、プロダクトのツールチェーン、生成AI呼び出しを実行する。既定の配置先は `.work/a2o/agent/bin/a2o-agent` である。

次に全体診断を行う。

```sh
a2o doctor
```

`status=blocked` の確認項目がある場合は、表示された `action=` を先に直す。

## 7. タスクを 1 つ作る

1. `a2o kanban url` でボードを開く。
2. `project-package/task-templates/` をもとにタスクを作る。
3. タスクを `project.yaml` の `kanban.selection.status` に置く。既定は `To do`。
4. タスクにトリガーラベルと、必要ならリポジトリラベルを付ける。

`a2o kanban up` はレーンとラベルを用意するが、作業タスクは自動投入しない。

## 8. A2O に実行させる

初回確認では 1 回だけ実行する。

```sh
a2o runtime run-once
```

常駐スケジューラとして動かす場合は次を使う。

```sh
a2o runtime resume --interval 60s --agent-poll-interval 5s
a2o runtime status
a2o runtime pause
```

`runtime resume` はタスク処理を自動開始する。`runtime pause` は現在の作業が終わったあとにスケジューラを止める予約である。コンテナの起動・停止だけを扱いたい場合は `a2o runtime up` / `a2o runtime down` を使う。

## 9. 結果を確認する

```sh
a2o runtime watch-summary
a2o runtime describe-task <task-ref>
```

`watch-summary` はボード上の複数タスク、スケジューラの状態、実行中のフェーズをまとめて見る。`describe-task` は 1 タスクの実行、証跡、カンバンコメント、ログの手がかりを表示する。

タスクにエージェント実行の成果物がある場合、`describe-task` は `agent_artifact_read` コマンドを表示する。

```sh
a2o runtime show-artifact <artifact-id>
```

ボード上の `Done` は A2O による自動処理が完了した状態である。Kanbalone の `Resolved` / `done=true` は人間の最終確認を表す別状態である。

## 問題が起きたら

まず次を見る。

```sh
a2o doctor
a2o runtime watch-summary
a2o runtime describe-task <task-ref>
```

エラー分類、エージェント成果物、ブロックされたタスクの復旧手順は [40-troubleshooting.md](40-troubleshooting.md) にまとめている。

## 次に読む文書

| 目的 | 文書 |
|---|---|
| プロジェクトパッケージの設計を理解する | [20-project-package.md](20-project-package.md) |
| ランタイム / カンバン / エージェント / イメージ更新を運用する | [30-operating-runtime.md](30-operating-runtime.md) |
| ブロックまたは失敗したタスクを調査する | [40-troubleshooting.md](40-troubleshooting.md) |
| 複数リポジトリ / 親子タスクの流れを使う | [50-parent-child-task-flow.md](50-parent-child-task-flow.md) |
| `project.yaml` の詳細を見る | [90-project-package-schema.md](90-project-package-schema.md) |
