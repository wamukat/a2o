# 現在の公開機能

A2O 0.5.30 で現在利用できる公開機能と検証範囲を示す。

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
- ランタイム診断・復旧: `a2o runtime image-digest`、`doctor`、`watch-summary`、`logs [task-ref] --follow`、`describe-task <task-ref>`、`skill-feedback list`、`skill-feedback propose`、`reset-task <task-ref>`、`show-artifact <artifact-id>`
- アップグレード診断: `a2o upgrade check`
- 単一ファイルのプロジェクトパッケージ設定: `project.yaml`
- agent server 接続向けの project runtime 調整項目: `runtime.agent_control_plane_connect_timeout`、`runtime.agent_control_plane_request_timeout`、`runtime.agent_control_plane_retry_count`、`runtime.agent_control_plane_retry_delay`
- child / single タスク向けの任意 review gate 項目: `runtime.review_gate.child`、`runtime.review_gate.single`
- 外部 Kanbalone bootstrap 項目: `--kanban-mode external`、`--kanban-url`、`--kanban-runtime-url`
- agent server 接続向けの runtime CLI 上書き: `--agent-control-plane-connect-timeout`、`--agent-control-plane-request-timeout`、`--agent-control-plane-retries`、`--agent-control-plane-retry-delay`
- agent server 接続向けの host agent CLI / runtime profile 項目: `--control-plane-connect-timeout`、`--control-plane-request-timeout`、`--control-plane-retries`、`--control-plane-retry-delay`、`control_plane_connect_timeout`、`control_plane_request_timeout`、`control_plane_retry_count`、`control_plane_retry_delay`
- Kanbalone アダプターと初期化ツール。既定の Kanbalone イメージは `v0.9.19`
- エージェント HTTP ワーカー境界。取得済みジョブの heartbeat を含む
- エージェントが具体化するワークスペース方式
- TypeScript、Go、Python、複数リポジトリタスクテンプレートの参照用プロダクトパッケージ
- GHCR ランタイムイメージタグ: `latest`、`0.5.30`、`sha-*`
- タグリリースでは `latest` も同時に公開する。そのため、公開完了後はリリース版タグと `latest` が同じランタイムイメージを指す前提で確認する。
- ローカルリリース判定: RSpec 全体

## 検証範囲

参照用プロダクト群では、単一リポジトリと複数リポジトリのタスク処理を、カンバン、エージェント境界、検証、マージ、親子タスク処理、ランタイム要約表示、`describe-task` の診断、証跡保持まで通して確認する。

## 変更境界

未対応のプロダクト作業は、実装前に A2O カンバンで追跡する。外部仕様の変更が必要な場合は、実装前に owner と協議する。
