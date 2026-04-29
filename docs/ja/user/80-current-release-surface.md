# 現在の公開機能

A2O 0.5.52 で現在利用できる公開機能と検証範囲を示す。

この文書は、リリース時点で「利用者に案内してよい機能」と「検証済みとして扱える範囲」を確認するための一覧である。導入手順を知りたい場合は [10-quickstart.md](10-quickstart.md)、設定項目を知りたい場合は [90-project-package-schema.md](90-project-package-schema.md) を読む。

## 利用可能なコマンドと機能

- ホスト用ランチャーの導入: `a2o host install`
- バージョン確認: `a2o version`
- ホスト環境の診断: `a2o doctor`
- プロジェクトパッケージの作成・検証・初期化: `a2o project template`、`lint`、`validate`、`bootstrap`
- ワーカー補助コマンド: `a2o worker scaffold`、`a2o worker validate-result`
- カンバンサービスの起動・外部 Kanbalone 診断: `a2o kanban up`、`doctor`、`url`
- エージェント対象の判定とバイナリの書き出し: `a2o agent target`、`a2o agent install`
- ランタイムコンテナの起動・停止: `a2o runtime up`、`down`
- 手動でのランタイム実行: `a2o runtime run-once`、`a2o runtime loop`
- 常駐スケジューラの再開・停止予約・状態確認: `a2o runtime resume`、`pause`、`status`
- ランタイム診断・復旧: `a2o runtime image-digest`、`doctor`、`watch-summary`、`logs [task-ref] --follow [--no-children]`、`describe-task <task-ref>`、`skill-feedback list`、`skill-feedback propose`、`reset-task <task-ref>`、`force-stop-task <task-ref> --dangerous`、`force-stop-run <run-ref> --dangerous`、`show-artifact <artifact-id>`
- 親タスクの log follow は、実行中の子タスクが完了して別の子または親タスク側へ処理が移っても、親グループを追跡し続ける。
- `watch-summary` は review の rework / reject を `x` として表示し、後続の正常な review 完了後は成功 marker に戻す。
- correction retry を使い切った invalid worker result は salvage 診断として保持されるため、operator は拒否された payload を失わずに確認できる。
- review rework 後の implementation retry には、直前の review feedback が worker runtime context として渡される。
- operator が付与した `blocked` label は phase 完了時にも保持され、runtime status publication によって暗黙に外されない。
- parent review の clean success result は、worker が `review_disposition` を省略または一部だけ返しても completed disposition に正規化される。明示的に矛盾する disposition は引き続き拒否される。frozen worker payload でも、この正規化で scheduler がクラッシュしない。
- multi-project runtime context の土台として、manual multi-project lifecycle command を有効化する前に、runtime storage、host log / workspace、scheduler pid / log file、temp file、branch namespace を解決済み project key ごとに分離する。
- アップグレード診断: `a2o upgrade check`
- 単一ファイルのプロジェクトパッケージ設定: `project.yaml`
- investigate decomposition MVP: `runtime.decomposition.investigate.command`、`runtime.decomposition.author.command`、`a2o runtime decomposition investigate`、`propose`、`review`、`create-children`、`status`、`cleanup`
- decomposition command UX: `a2o runtime decomposition <action> --help` の action-level help と、単発 decomposition command の外部 task 同期 / 照合
- gate closed の decomposition child creation は、空の `success=` を表示せず、`status=gate_closed` と `child_creation_result=not_attempted` を表示する
- project prompt composition: `runtime.prompts.repoSlots` は multi-repo の `repo_scope=both` task で、task の `edit_scope` 順に各 repo slot の prompt / skill addon を合成する。
- prompt diagnostics / evidence は順序付きの `project_prompt.repo_slots` を出力する。従来の単数 `repo_slot` は single-slot task の場合だけ設定される。
- prompt preview は `a2o prompt preview --repo-slot app --repo-slot lib` または `a2o prompt preview --repo-slot app,lib` のように、複数 repo slot を指定した multi-repo 合成確認に対応する。
- agent server 接続向けの project runtime 調整項目: `runtime.agent_control_plane_connect_timeout`、`runtime.agent_control_plane_request_timeout`、`runtime.agent_control_plane_retry_count`、`runtime.agent_control_plane_retry_delay`
- child / single タスク向けの任意 review gate 項目: `runtime.review_gate.child`、`runtime.review_gate.single`、`runtime.review_gate.skip_labels`、`runtime.review_gate.require_labels`
- 外部 Kanbalone bootstrap 項目: `--kanban-mode external`、`--kanban-url`、`--kanban-runtime-url`
- agent server 接続向けの runtime CLI 上書き: `--agent-control-plane-connect-timeout`、`--agent-control-plane-request-timeout`、`--agent-control-plane-retries`、`--agent-control-plane-retry-delay`
- agent server 接続向けの host agent CLI / runtime profile 項目: `--control-plane-connect-timeout`、`--control-plane-request-timeout`、`--control-plane-retries`、`--control-plane-retry-delay`、`control_plane_connect_timeout`、`control_plane_request_timeout`、`control_plane_retry_count`、`control_plane_retry_delay`
- Kanbalone アダプターと初期化ツール。既定の Kanbalone イメージは `v0.9.24`
- エージェント HTTP ワーカー境界。取得済みジョブの heartbeat を含む
- エージェントが具体化するワークスペース方式
- TypeScript、Go、Python、複数リポジトリタスクテンプレートの参照用プロダクトパッケージ
- GHCR ランタイムイメージタグ: `latest`、`0.5.52`、`sha-*`
- タグリリースでは `latest` も同時に公開する。そのため、公開完了後はリリース版タグと `latest` が同じランタイムイメージを指す前提で確認する。
- ローカルリリース判定: RSpec 全体、release package doctor、local RC host smoke、および runtime 実行 / worker launcher / scheduler / Kanban / env generation 変更時の real-task local RC smoke

## マイグレーション案内

- `a2o runtime start` と `a2o runtime stop` は互換 alias ではなくなった。常駐スケジューラを再開する場合は `a2o runtime resume`、現在の作業後に停止予約する場合は `a2o runtime pause` を使う。削除済みコマンドを実行した場合、A2O は非ゼロで終了し、`migration_required=true` と移行先コマンドを表示する。
- SoloBoard 時代の Kanbalone 互換名は削除された。`KANBAN_BACKEND=kanbalone`、`KANBALONE_BASE_URL`、`KANBALONE_API_TOKEN`、`--kanbalone-port`、`A2O_BUNDLE_KANBALONE_PORT`、`A2O_KANBALONE_INTERNAL_URL` を使う。削除済み SoloBoard 入力を使った場合は `migration_required=true` と置き換え先を表示する。
- 同梱 Kanbalone のデータ名は `<compose-project>_soloboard-data` / `soloboard.sqlite` から `<compose-project>_kanbalone-data` / `kanbalone.sqlite` に変わった。旧 volume が存在し、新 volume が存在しない場合、`a2o kanban up` は空の board を作らず `migration_required=true` で停止する。同梱サービスを起動する前に、既存の Kanban data を copy または rename する。
- runtime / agent / worker / root utility 設定の公開 `A3_*` 環境変数 fallback は、`A2O_*` 置き換えがあるものから削除された。`A2O_RUNTIME_IMAGE`、`A2O_COMPOSE_PROJECT`、`A2O_COMPOSE_FILE`、`A2O_RUNTIME_SERVICE`、`A2O_BUNDLE_AGENT_PORT`、`A2O_BUNDLE_STORAGE_DIR`、`A2O_AGENT_PACKAGE_DIR`、`A2O_AGENT_TOKEN`、`A2O_AGENT_TOKEN_FILE`、`A2O_AGENT_CONTROL_TOKEN`、`A2O_AGENT_CONTROL_TOKEN_FILE`、`A2O_AGENT_*`、`A2O_WORKER_*`、`A2O_WORKSPACE_ROOT`、`A2O_ROOT_DIR`、`A2O_ROOT_*` root utility controls を使う。削除済み `A3_*` 入力を使った場合は `migration_required=true` と置き換え先を表示する。
- `worker-runs.json` は activity state source ではなくなった。operator diagnostics、cleanup、rerun readiness、reconcile、watch-summary は `agent_jobs.json` を使う。残存する `worker-runs.json` は `migration_required=true` として報告される。
- 公開 agent package と host launcher artifact は `a2o-agent` / `a2o` 名を使う。リリース archive は `a2o-agent-<version>-<os>-<arch>.tar.gz`、archive 内バイナリは `a2o-agent`、host install は `a2o` と `a2o-<os>-<arch>` のみを書き出す。shell installer は install directory に残った `a3*` ファイルを削除する。旧 package / cache 環境変数名は `migration_required=true` で失敗する。runtime image 内の `a3 agent package ...` も `migration_required=true` で失敗するため、`a2o agent package ...` を使う。

## 検証範囲

参照用プロダクト群では、単一リポジトリと複数リポジトリのタスク処理を、カンバン、エージェント境界、検証、マージ、親子タスク処理、ランタイム要約表示、`describe-task` の診断、証跡保持まで通して確認する。

## 変更境界

未対応のプロダクト作業は、実装前に A2O カンバンで追跡する。外部仕様の変更が必要な場合は、実装前に owner と協議する。
