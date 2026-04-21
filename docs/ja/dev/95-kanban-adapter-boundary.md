# カンバンアダプター境界

この文書は、A2O Engine がカンバンタスクを読み書きするときのアダプター境界を定義する。ランタイムの流れでは、スケジューラのタスク選択、状態公開、コメント / 証跡の報告、親子タスク関係の管理がこの境界を通る。

読む目的は、A2O のドメイン状態と Kanbalone の API / CLI 仕様を直接混ぜないための境界を理解することである。Kanbalone は SoloBoard からリネームされた後継であり、内部アダプター名には互換用 backend 識別子として `soloboard` が残る箇所がある。カンバンは利用者に見えるタスクキューだが、Engine 内部では操作単位のクライアントを通して読み書きし、レーン名や解決済みフラグの意味を明示的に変換する。

## 現在の契約

A2O Engine は現在、`tools/kanban/cli.py` と互換のコマンド契約を通じてカンバンと通信する。ランタイムは次の操作を使う。

- 読み取り操作: `task-snapshot-list`、`task-watch-summary-list`、`task-get`、`task-label-list`、`task-relation-list`、`task-find`
- 書き込み操作: `task-transition`、`task-comment-create`、`task-create`、`label-ensure`、`task-label-add`、`task-label-remove`、`task-relation-create`
- テキスト受け渡し: 長い説明文やコメントは、シェルクォートと引数長の問題を避けるため `--*-file` 形式のオプションを使う。

コマンド契約は外部ツール向けの面である。内部では Ruby コードが進行処理の各所でサブプロセス呼び出しを散らさず、操作クライアント境界を通じてカンバンにアクセスする。

## Done と Resolved

A2O は自動処理の完了と人間の最終確認を分けて扱う。

- `status=Done` は、A2O がタスクの自動処理を完了したことを示す。対象フェーズがある場合は、実装、検証、マージの完了を含む。
- Kanbalone の `done=true` / `isResolved=true` は、ボード上で人間がタスクを解決済みと確認したことを示す。
- A2O ランタイムの状態公開はタスクを `Done` レーンへ移すが、Kanbalone の解決済みフラグは設定しない。
- `task-transition --sync-done-state` は、運用者が人間による解決済みフラグも同期したい場合にだけ使う。

そのため Kanbalone スナップショットで `status=Done` かつ `done=false` になっていても正常である。ランタイムのタスク選択、要約表示、報告はレーン / 状態を A2O の自動処理状態として使い、`done=false` をマージ失敗や自動処理未完了として扱ってはいけない。

## アダプター構造

カンバンアクセスは Ruby の操作クライアント境界を中心に構成する。

1. `tools/kanban/cli.py` はコマンド契約用の開発者 / 運用者 CLI である。
2. Engine コードは、操作単位の JSON / テキスト補助機能を持つ `A3::Infra::KanbanCommandClient` 経由でカンバン操作を実行する。
3. `SubprocessKanbanCommandClient` は、その境界の背後にある現在の本番用 Kanbalone 互換実装である。
4. 追加プロバイダー実装は、ランタイム既定値になる前に同じ操作単位の意味論を維持する必要がある。

## ランタイムの Python 依存

A2O 0.5.7 は `docker/a3-runtime/Dockerfile` に `python3` を残すが、`python3-venv` はインストールしない。

現在のランタイムには、まだ Engine が所有する Python 依存がある。

- Go 製ホストランチャーは、ランタイムコマンドを `--kanban-command python3` 付きで組み立てる。
- コマンド引数は `a3-engine/tools/kanban/cli.py` を指す。
- Ruby Engine のブリッジ構築は、まだ `subprocess-cli` カンバンバックエンドを既定値にしている。
- `SubprocessKanbanCommandClient` は、`KanbanCommandClient` の背後にある唯一の本番用 Kanbalone 互換実装である。

そのため、サブプロセス CLI がランタイム既定値である間にランタイムイメージから Python を削除すると、標準の `a2o kanban ...` ランタイム経路が壊れる。

## 現在のアダプター境界

`A3::Infra::KanbanCommandClient` は操作単位の境界であり、タスクソース、状態公開、アクティビティ公開、後続子タスク書き込み、スナップショット読み取りが使う。コンストラクタは `command_argv` を受け取り、`SubprocessKanbanCommandClient` を作成する。そのため、ランタイムの振る舞いと公開 CLI 引数は安定する。

## 互換要件

ネイティブアダプターは次を維持しなければならない。

- `Project#123` のような正規タスク参照
- 重複参照がある場合の外部タスク ID 優先
- `To do`、`In progress`、`In review`、`Inspection`、`Merging`、`Done` の状態対応
- ブロックラベルの追加 / 削除動作
- 親子タスク用の関連構造
- 複数行テキストを含むコメント / 説明ファイルの意味論
- JSON オブジェクト / 配列の形の検証と即時失敗エラー

現在のコマンド契約を維持するために、Kanbalone API や公開カンバン CLI の変更は不要である。

## 複数行テキストの契約

自動処理はタスク説明とコメントを `--description-file`、`--append-description-file`、`--comment-file` のようなファイル指定オプションで渡す。カンバン CLI の書き込み成功時は stdout に JSON だけを返すため、呼び出し側はテキスト抽出ではなく JSON パーサーでタスク ID / 参照を取得する。

`task-create --description-file` と `task-update --description-file` は複数行 Markdown を `description` に保持する。`task-snapshot-list` はバックエンド応答から得られる最良の `description` を含め、ダッシュボードやログ用に 1 行プレビューの `description_summary` も含める。`description_source` は `detail`、`list`、`empty` のいずれかで、本文が詳細エンドポイント、一覧ペイロード、または未取得のどれに由来するかを示す。`description` が空の場合は、そのタスクの本文をどのバックエンド応答も返さなかったことを示し、JSON の受け渡し失敗ではない。
