# トラブルシューティング

この文書は、A2O の実行が止まったときに、どこを見て何を直すかを説明する。日常運用コマンドは [30-operating-runtime.md](30-operating-runtime.md) を読む。

読む目的は、失敗時にログを探し回るのではなく、`doctor`、`status`、`watch-summary`、`describe-task` の順で原因を絞ることである。A2O は失敗を設定不備、未整理のリポジトリ、実行コマンド失敗、検証失敗、マージ競合などに分類するため、まず分類を見てから対象ファイルやコマンドを直す。

## 最初に見るもの

```sh
a2o doctor
a2o runtime status
a2o runtime watch-summary
a2o runtime describe-task <task-ref>
```

`a2o doctor` はプロジェクトパッケージ、実行コマンド設定、必須コマンド、リポジトリの整理状態、エージェント配置、カンバンサービス、ランタイムコンテナ、ランタイムイメージのダイジェストをまとめて確認する。

`runtime status` はスケジューラとランタイムインスタンスの状態を見る。`watch-summary` は複数タスクの現在位置を見る。`describe-task` は 1 タスクの実行、フェーズ、ワークスペース、証跡、カンバンコメント、ログの手がかりを集約して表示する。

## 症状別の見方

| 症状 | まず見るコマンド | よくある原因 | 直すもの |
| --- | --- | --- | --- |
| タスクが進まない | `a2o runtime status` | スケジューラまたはランタイムコンテナが止まっている | `a2o runtime up`、`a2o runtime start` |
| ボードが空に見える | `a2o kanban doctor` | Compose プロジェクト / Docker volume が変わった | インスタンス設定、Compose プロジェクト、volume |
| タスクがブロックされた | `a2o runtime describe-task <task-ref>` | 設定不備、未整理のリポジトリ、実行コマンド失敗、検証失敗、マージ競合 | 表示されたエラー分類の対象 |
| Docker credential helper で止まる | `a2o doctor` | Docker 設定が存在しない credential helper を指している | `credsStore` / `credHelpers`、または一時 `DOCKER_CONFIG` |
| 実行コマンドが起動しない | `a2o doctor` | `your-ai-worker` の置き換え漏れ、バイナリ不足、認証情報不足 | `project.yaml`、`agent.required_bins`、AI ワーカー設定 |
| 未整理のリポジトリで止まる | `a2o runtime describe-task <task-ref>` | 未保存変更や生成ファイルが残っている | 表示されたリポジトリ / ファイルを commit / stash / remove |
| 検証が失敗する | `a2o runtime describe-task <task-ref>` | プロダクトのテスト失敗、依存関係、整形、修復失敗 | プロジェクトコマンド、テスト、依存関係 |
| マージできない | `a2o runtime describe-task <task-ref>` | 競合、ターゲット参照の変更、方針不一致 | Git ブランチ、ターゲット参照、競合 |
| イメージが想定と違う | `a2o runtime image-digest` | 固定参照 / ローカル参照 / 実行中イメージの不一致 | ランタイムイメージの固定、pull、再起動 |

## エラー分類

A2O の stderr とカンバンコメントには `error_category` と次の action が出る。

| Category | 意味 | 直すもの |
| --- | --- | --- |
| `configuration_error` | プロジェクトパッケージや実行コマンド設定が不正 | `project.yaml`、パッケージパス、スキーマ、プレースホルダー |
| `workspace_dirty` | リポジトリに未保存変更がある | 未整理のリポジトリとファイル |
| `executor_failed` | AI ワーカーまたは実行コマンドが失敗 | 実行ファイル、認証情報、ワーカー結果 JSON |
| `verification_failed` | プロダクトの検証が失敗 | tests、lint、依存関係、修復コマンド |
| `merge_conflict` | マージ競合が起きた | 競合ファイル、base ブランチの状態 |
| `merge_failed` | マージ方針またはターゲット参照で失敗 | マージ先、ブランチ方針 |
| `runtime_failed` | Docker、Compose、ランタイムプロセスが失敗 | 表示されたコマンド出力、Docker の状態 |

## タスクの詳細を見る

```sh
a2o runtime describe-task <task-ref>
```

`describe-task` では次を見る。

- `latest_blocked` のフェーズと要約
- `blocked_error_category`
- ワークスペースとソース参照
- 証跡の場所
- カンバンコメントの要約
- `host_agent_log` を含む operator log の場所
- `agent_artifact_read` コマンド

エージェント成果物がある場合は、表示されたコマンドで実行コマンドの stdout/stderr やワーカー結果を読む。

```sh
a2o runtime show-artifact <artifact-id>
```

生成AIの生ログを A2O 側で見たい場合は、プロジェクトの実行コマンドまたは AI CLI が transcript を stdout / stderr またはワーカー結果に書くようにする。A2O はそれをエージェント実行の成果物として保持する。

`host_agent_log` は scheduler / control-plane / host agent 側の補助診断ログである。source of truth は `describe-task` に出る run、blocked diagnosis、evidence、artifact であり、operator log はそれを補足するために読む。

## 未整理のリポジトリの直し方

未整理のリポジトリで即時停止するのは、A2O が利用者の未保存変更を上書きしないためである。

1. `a2o runtime describe-task <task-ref>` で未整理のリポジトリとファイルを確認する。
2. 必要な変更なら commit する。
3. 一時退避でよいなら stash する。
4. 不要な生成ファイルなら remove する。
5. `a2o doctor` で整理済み状態を確認する。

生成されたランタイムファイルがプロダクトのリポジトリルートに出ている場合は、プロジェクトパッケージやエージェント配置先を確認する。A2O の生成データは `.work/a2o/` 配下に閉じるのが基本である。

## Docker credential helper の直し方

`a2o doctor` が `docker_credential_helpers status=blocked` を出す場合、Docker 設定の `credsStore` または `credHelpers` が、現在のホストに存在しない `docker-credential-*` バイナリを指している。

確認するもの:

- `~/.docker/config.json`
- `DOCKER_CONFIG` を使っている場合は `$DOCKER_CONFIG/config.json`
- `credsStore`
- `credHelpers`
- `docker-credential-<name>` が `PATH` にあるか

Docker の credential helper を使うなら、該当バイナリをインストールする。使わないなら Docker 設定の `credsStore` / `credHelpers` を直す。

一時的に最小構成の Docker 設定で確認したい場合は、空の `auths` だけを持つ設定を使う。

```sh
tmp_docker_config="$(mktemp -d)"
printf '{"auths":{}}\n' > "$tmp_docker_config/config.json"
DOCKER_CONFIG="$tmp_docker_config" a2o doctor
```

この確認で通る場合は、A2O ではなく通常の Docker 設定が原因である。恒久対応として、通常利用する Docker 設定を修正する。

## ブロックされたタスクの復旧

```sh
a2o runtime reset-task <task-ref>
```

`reset-task` は予行演習として復旧手順を表示する。カンバン、ランタイム状態、ワークスペース、ブランチは変更しない。

推奨手順:

1. `a2o runtime describe-task <task-ref>` でブロック理由、証跡、コメント、ログを読む。
2. `a2o runtime watch-summary` で関連タスクが実行中ではないことを確認する。
3. 設定不備、未整理のリポジトリ、コマンド不足、実行コマンドの認証情報、検証失敗、マージ競合などの根本原因を直す。
4. ワークスペース / ブランチに残った手動変更が必要なら commit / patch / discard を明示的に行う。
5. `a2o doctor` で根本原因が残っていないことを確認する。
6. `a2o runtime run-once` を実行するか、常駐スケジューラに再取り込みさせる。

ブロックラベルやブロック状態は、次のランタイム試行がタスクを非ブロック状態へ進めるときに A2O が更新する。通常利用では、公開 `a2o` コマンドで手動解除しようとしない。

## カンバンが空に見える

`a2o kanban up` は Compose プロジェクトと Docker volume を使う。Compose プロジェクトが変わると別 volume になり、同じプロダクトでも別ボードに見える。

確認するもの:

- `.work/a2o/runtime-instance.json` の Compose プロジェクト
- `a2o runtime status` のカンバン / ランタイムインスタンス情報
- `a2o kanban doctor` のサービス / ボード情報
- Docker volume 名

既存ボードを使うか、新しいボードを作るか、バックアップ / リセットするかを決めてから `a2o kanban up` を実行する。

## どのコマンドから戻るか

原因を直した後は、広い診断から戻す。

```sh
a2o doctor
a2o runtime status
a2o runtime watch-summary
```

スケジューラが動いていれば、次の実行間隔でタスクが再取り込みされる。すぐ確認したい場合だけ `a2o runtime run-once` を使う。
