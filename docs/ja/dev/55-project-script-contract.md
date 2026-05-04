# プロジェクトスクリプトの契約

A2O はプロジェクトパッケージがプロダクト固有の自動化を持つことを許容する。パッケージスクリプトは Ruby、Bash、Go、Python、Node、その他プロジェクト内で保守できる選択でよい。安定させる境界はスクリプトの言語ではなく、A2O が提供するコマンド、環境変数、要求、結果、ワークスペース、証跡の契約である。

読む目的は、プロジェクト固有スクリプトが A2O の内部ファイルに依存せず、公開された要求 JSON と環境変数だけで動けるようにすることである。スクリプトの言語選択はプロジェクト側の判断でよいが、入力、出力、失敗時の情報は A2O が解釈できる形に揃える。

## ランタイムの流れ上の位置づけ

この文書は、A2O Engine がフェーズジョブを作り、a2o-agent がプロジェクトコマンドを実行するときの契約を定義する。プロジェクトスクリプトはワークスペース構成を推測せず、公開環境変数とワーカー要求 JSON を正本として扱う。

## 責務

A2O が所有するもの:

- フェーズライフサイクルと許可されるフェーズ名
- カンバンタスク選択と遷移
- ワークスペース具体化とリポジトリスロットのパス
- ワーカー要求 / 結果の受け渡し
- 証跡の公開とマージ進行
- 診断分類と修復の手がかり

プロジェクトパッケージが所有するもの:

- プロダクトのビルド、テスト、検証、修復コマンド
- ローカル依存キャッシュの準備など、プロジェクト固有の初期化
- そのプロダクトが必要とする補助リポジトリの準備
- 任意のメトリクス収集コマンド
- 実装 / レビューで使う AI または結果が決まっている実行コマンド

プロジェクトスクリプトは `.a2o/workspace.json`、`.a2o/slot.json`、`.a2o/worker-request.json`、`.a2o/worker-result.json`、生成された `launcher.json`、内部 A3 環境変数名のような非公開ランタイムファイルに依存してはならない。

## フェーズコマンドの契約

A2O はパッケージコマンド用に次の公開フェーズを定義する。

- `implementation`
- `review`
- `parent_review`
- `verification`
- `remediation`
- `merge`

実装、レビュー、親タスクレビューはワーカープロトコル経由で実行する。検証と修復は具体化済みワークスペース内のプロジェクトコマンドとして実行する。マージは方針で設定し、A2O が実行する。プロジェクトパッケージはサポート済みのマージ動作を選ぶだけで、新しいマージエンジンを実装しない。

実行コマンドは次のプレースホルダーを使える。

- `{{result_path}}`
- `{{schema_path}}`
- `{{workspace_root}}`
- `{{a2o_root_dir}}`
- `{{root_dir}}`

検証コマンドと修復コマンドは次を使える。

- `{{workspace_root}}`
- `{{a2o_root_dir}}`
- `{{root_dir}}`

メトリクス収集コマンドは、検証 / 修復コマンドと同じプレースホルダーを使える。実行されるのは検証成功後だけである。

## ワーカー環境

プロジェクトワーカー、検証コマンド、修復コマンドは次の環境変数を使う。

- `A2O_WORKER_REQUEST_PATH`: 現在のジョブの JSON 要求一式。
- `A2O_WORKER_RESULT_PATH`: ワーカーコマンドが最終 JSON 結果を書き込むパス。
- `A2O_WORKSPACE_ROOT`: 現在のジョブの具体化済みワークスペースルート。
- `A2O_ROOT_DIR`: ワーカーから見える A2O ランタイム補助ファイルのルートディレクトリ。
- `A2O_WORKER_LAUNCHER_CONFIG_PATH`: 標準入力バンドル用ワーカーが使う生成済みランチャー設定。

`A3_*` 名は互換エイリアスに限定する。公開プロジェクトスクリプト契約ではない。

## 要求の契約

ワーカー要求 JSON はプロジェクトスクリプトにとっての正本である。含まれるもの:

- `task_ref`、`run_ref`、`phase`
- `skill`
- 検証 / 修復コマンドのジョブでは `command_intent`
- メトリクスジョブでは `command_intent=metrics_collection`
- `task_packet.title` と `task_packet.description`
- リポジトリスロット別名をキーにした `slot_paths`
- タスク種別や必要に応じた検証コマンドを含む `phase_runtime`
- ソース記述子とスコープスナップショットのメタデータ

スクリプトはワークスペースのディレクトリ構成を推測せず、リポジトリパスを `slot_paths` から読む。
スロット単位の修復では、コマンドの作業ディレクトリがリポジトリスロットになる場合があるが、`A2O_WORKSPACE_ROOT` と `slot_paths` は準備済みワークスペース全体を指す。
非公開の `.a2o/.a3` メタデータを直接読まず、`A2O_WORKER_REQUEST_PATH` を使う。

## メトリクス結果の契約

メトリクス収集コマンドは worker result file を書かない。stdout に JSON オブジェクトを 1 つ出す。A2O は runtime が所有するメタデータを合成し、task metrics record として保存する。

プロジェクトが所有できるトップレベルセクションは次の通り。

- `code_changes`
- `tests`
- `coverage`
- `timing`
- `cost`
- `custom`

各セクションは JSON オブジェクトでなければならない。コマンドが `task_ref`、`parent_ref`、`timestamp` を含める場合、その値は runtime context と一致していなければならない。一致しない場合や、不正 JSON、未対応セクション、オブジェクトではないセクション値は metrics diagnostics として記録され、成功済みの検証結果は隠さない。

## 結果の契約

ワーカーコマンドは `A2O_WORKER_RESULT_PATH` に JSON オブジェクトを 1 つ書く。必須キーは次の通り。

- `task_ref`
- `run_ref`
- `phase`
- `success`
- `summary`
- `failing_command`
- `observed_state`
- `rework_required`

実装成功時はリポジトリスロットごとの `changed_files` も含める。レビューと親タスクレビューは、ワーカー応答スキーマに従って `review_disposition` を含められる。`review_disposition` の scope の正規キーは `slot_scopes` であり、`["repo_alpha"]` や `["repo_alpha", "repo_beta"]` のようなリポジトリスロット名の非空配列とする。`review_disposition` 内の `repo_scope` は受け付けない。`finding_key` は actionable な `follow_up_child` / `blocked` finding の場合のみ必須であり、clean な `completed` review evidence では省略または `null` にできる。

validation は意図的に分ける。

- JSON Schema / basic-shape validation は、JSON として読めること、object shape、primitive type、常に必須の key だけを確認する。
- semantic validation は、phase や disposition に依存する不変条件を確認する。例: implementation success の `changed_files`、有効な `slot_scopes`、actionable finding の場合だけ非空必須となる `finding_key`。
- clean review evidence は finding identifier を持たないことだけで blocked にしてはならない。A2O が拒否すべきなのは、routing や follow-up child 作成に影響する矛盾であり、非 actionable metadata の欠落ではない。

worker result には、実装またはレビューで設計負債を見つけた場合に任意の `refactoring_assessment` を含められる。A2O は schema、validation、evidence 保存、短い Kanban comment summary を持つ。何を負債とみなすか、現在の child に含めてよい条件、別 child / follow-up に分ける条件は project package が prompt / skill / docs で定義する。`disposition` は `none`、`include_child`、`defer_follow_up`、`blocked_by_design_debt`、`needs_clarification` のいずれか。`recommended_action` は `none`、`document_only`、`include_in_current_child`、`create_refactoring_child`、`create_follow_up_child`、`request_clarification`、`block_until_decision` のいずれか。

```json
{
  "refactoring_assessment": {
    "disposition": "defer_follow_up",
    "reason": "新しい分岐が既存の Factory 選択ロジックの重複を増やす。",
    "scope": ["repo_beta/app/services/address"],
    "recommended_action": "create_follow_up_child",
    "risk": "medium",
    "evidence": ["Factory A と Factory B がすでに同じ責務を持つ。"]
  }
}
```

`defer_follow_up` は、作業を継続してよいが負債を evidence に残す判断である。`include_child` は decomposition または parent review flow で refactoring child を含める判断である。`blocked_by_design_debt` と `needs_clarification` は一般的な技術失敗ではなく、project policy 上、安全な実装に設計判断または依頼者入力が必要な場合に使う。

## キャッシュと成果物

タスク単位のキャッシュと成果物パスは、A2O が管理するワークスペースの責務である。プロジェクトパッケージは具体化済みワークスペース配下にプロダクト固有のキャッシュディレクトリを作ってよいが、永続キャッシュ方針と証跡保持は A2O が所有する。新しい安定したキャッシュ / 成果物検出ヘルパーが必要な場合は、スクリプトが内部ランタイムパスに依存する前に A2O 契約として追加する。

## 検証方針

`a2o doctor`、`a2o project lint`、`a2o worker validate-result` は次を検出する。

- プロジェクトパッケージ内の `A3_*` ワーカー環境変数名
- 非公開の `.a2o/.a3` メタデータファイルの直接読み取り
- 必須ワーカー結果キーの欠落
- 公開プレースホルダーを使っていない実行コマンド
- 宣言されていないバイナリを必要とする検証 / 修復コマンド

Lint の出力には次の修正手順を含める。例えば `A3_*` 名は対応する `A2O_*` 変数へ、`.a2o/.a3` メタデータの読み取りは `A2O_WORKER_REQUEST_PATH` の `slot_paths`、`scope_snapshot`、`phase_runtime` へ、`launcher.json` 参照は `project.yaml` のフェーズ実行コマンド設定へ誘導する。

目的は、プロジェクト固有の自動化を可能にしたまま、A2O リリース間で安定した境界を維持することである。
