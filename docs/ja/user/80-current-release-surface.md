# 現在の公開機能

A2O 0.5.5 で現在利用できる公開機能と検証範囲を示す。

## 利用可能なコマンドと機能

- ホスト用ランチャーの導入: `a2o host install`
- プロジェクトの初期化: `a2o project bootstrap`、任意で `--package DIR`
- カンバンサービスの起動・診断: `a2o kanban up`、`doctor`、`url`
- エージェントバイナリの書き出し: `a2o agent install`
- ランタイムコンテナの起動・停止: `a2o runtime up`、`down`
- 手動でのランタイム実行: `a2o runtime run-once`、`a2o runtime loop`
- 常駐スケジューラの起動・停止・状態確認: `a2o runtime start`、`stop`、`status`
- ランタイム診断: `a2o runtime doctor`、`a2o runtime watch-summary`、`a2o runtime describe-task <task-ref>`
- アップグレード診断: `a2o upgrade check`
- 単一ファイルのプロジェクトパッケージ設定: `project.yaml`
- SoloBoard アダプターと初期化ツール。既定の SoloBoard イメージは `v0.9.15`
- エージェント HTTP ワーカー境界
- エージェントが具体化するワークスペース方式
- TypeScript、Go、Python、複数リポジトリタスクテンプレートの参照用プロダクトパッケージ
- GHCR ランタイムイメージタグ: `latest`、`0.5.5`、`sha-*`
- ローカルリリース判定: RSpec 全体

## 検証範囲

参照用プロダクト群では、単一リポジトリと複数リポジトリのタスク処理を、カンバン、エージェント境界、検証、マージ、親子タスク処理、ランタイム要約表示、`describe-task` の診断、証跡保持まで通して確認する。

## 変更境界

未対応のプロダクト作業は、実装前に A2O カンバンで追跡する。外部仕様の変更が必要な場合は、実装前に owner と協議する。
