# A2O Evidence and Rerun Diagnosis

この文書は、review / verification / merge / rerun / blocked 調査の再現性を支える evidence model を固定するためのもの。
V1 のように phase ごとの場当たり的 JSON 断片へ依存せず、phase が読む内部証跡を先に定義する。

## 1. 目的

- review / merge / rerun / blocked 調査の再現性を保つ
- `review_target` と `source descriptor` の persisted form を定義する
- rerun 判定を evidence ベースで説明可能にする
- blocked diagnosis bundle の最小 canonical set を固定する

## 2. 設計方針

- evidence は内部証跡であり、公開 phase contract とは分ける
- phase は evidence を生成・更新してよいが、意味は domain が定義する
- blocked 診断は「stderr を眺めて推測する」ものではなく、canonical evidence set から再構成できるようにする

## 3. Canonical Evidence Set

phase をまたいで保持すべき evidence は、少なくとも次とする。

- `review_target`
- `source_descriptor`
- `integration_target`
- `merge_source`
- `merge_recovery`
- `artifact_owner`
- `verification_summary`
- `blocked_diagnosis`
- `scope_snapshot`

## 4. Evidence Objects

### 4.1 `ReviewTarget`

意味:

- review worker が監査対象として見た変更セットを再現するための evidence

最低限持つもの:

- `base_commit`
- `head_commit`
- `task_ref`
- `phase_ref`

### 4.2 `SourceDescriptor`

意味:

- phase が入力として何を materialize / inspect / merge したかを表す descriptor

最低限持つもの:

- `workspace_kind`
- `source_type`
  - `branch_head`
  - `detached_commit`
  - `integration_record`
- `ref_name` または `commit_sha`
- `task_ref`

### 4.3 `IntegrationTarget`

意味:

- merge や parent review / parent verification が対象とする branch/commit 系列

最低限持つもの:

- `target_ref`
- `target_head_commit`
- `task_ref`

### 4.4 `MergeSource`

意味:

- merge 時に取り込む source

最低限持つもの:

- `source_ref`
- `source_head_commit`
- `task_ref`

### 4.5 `MergeRecovery`

意味:

- merge phase 内で Git conflict を AI worker が解消した場合に、何を入力にし、何を解消し、どの guard を通して publish したかを再現するための evidence

最低限持つもの:

- `recovery_id`
- `merge_run_ref`
- `target_ref`
- `source_ref`
- `merge_before_head`
- `source_head_commit`
- `conflict_files`
- `resolved_conflict_files`
- `worker_result_ref`
- `changed_files`
- `marker_scan_result`
- `verification_run_ref`
- `publish_before_head`
- `publish_after_head`

### 4.6 `ArtifactOwner`

意味:

- artifact cache や runtime 生成物の ownership 単位

最低限持つもの:

- `owner_ref`
- `owner_scope`
- `snapshot_version`

### 4.7 `ScopeSnapshot`

意味:

- phase 開始時点で、どの scope が有効だったかの記録

最低限持つもの:

- `edit_scope`
- `verification_scope`
- `ownership_scope`

これにより、`repo scope` の意味を phase 後から再解釈せずに済む。

### 4.7 `SourceDescriptor` と `ScopeSnapshot` の責務境界

両者は似て見えるが、役割を分ける。

- `SourceDescriptor`
  - この phase が「どの作業面/入力源」を見たかを表す
  - 例: `ticket_workspace` / `runtime_workspace`, `branch_head` / `detached_commit`
- `ScopeSnapshot`
  - この phase が「どの責務範囲」を有効としていたかを表す
  - 例: `edit_scope`, `verification_scope`, `ownership_scope`

つまり:

- workspace の種別と source の形は `SourceDescriptor`
- 編集/検証/ownership の意味範囲は `ScopeSnapshot`

とし、同じ情報を二重保持しない。

### 4.8 `ReviewDisposition`

意味:

- parent review が「そのまま次 phase へ進むのか」「follow-up child を作るのか」「blocked なのか」を
  canonical に表す evidence

最低限持つもの:

- `kind`
  - `completed`
  - `follow_up_child`
  - `blocked`
- `repo_scope`
  - `repo_alpha`
  - `repo_beta`
  - `both`
  - `unresolved`
- `summary`
- `description`
- `finding_key`

`ReviewDisposition` は parent review completion の canonical input であり、
boolean の `rework_required` を parent review routing の正本にしない。

### 4.9 `FollowUpChildFingerprint`

意味:

- follow-up child write path の retry / dedupe / orphan recovery を支える stable identity

最低限持つもの:

- `parent_ref`
- `review_run_ref`
- `repo_scope`
- `finding_key`

この fingerprint は evidence と operator-visible comment の双方に残し、
`task-create success / relation-create failure` の partial failure 後でも
次回 retry で既存 child を attach できるようにする。

### 4.10 `SchedulerBlockedOutcome`

意味:

- task phase 開始前に prerequisite 不足が見つかったとき、scheduler exception ではなく
  operator-visible blocked として保存する evidence

初期対象:

- parent review / verification / merge 前の integration ref 欠落

最低限持つもの:

- `task_ref`
- `phase`
- `reason`
- `expected_state`
- `observed_state`
- `failing_command`
- `infra_diagnostics`

`SchedulerBlockedOutcome` は run start 前の blocked surface であり、
watch-summary / blocked diagnosis / recovery の正本として使う。

## 5. Persisted Form

evidence は phase 後に消える一時オブジェクトではなく、少なくとも rerun と blocked diagnosis をまたげる persisted form を持つ。

### TODO

- scheduler cycle history の persisted contract では、history append 後に scheduler state persist が失敗した場合の補償を維持すること。
- 具体的には `SchedulerCycleJournal` が partial cycle append を残さない順序で state/history を更新し、history append 失敗時は scheduler state を rollback できることを保つこと。
- shared scheduler store の error-path は backend ごとに確認すること。特に JSON / SQLite 実装では、atomic write 失敗時に state/history が部分反映されないことを回帰で固定すること。
- scheduler state/history の atomic contract は public bootstrap/container path を正規経路とすること。manual repository wiring は thin edge として扱い、追加の public assembly API へ寄せていくこと。

### 5.1 persist する単位

- `Run` 単位で evidence set を保持する
- `PhaseExecution` ごとに phase-specific evidence を追加する

つまり:

- run-level
  - task 全体の実行に共通する証跡
- phase-level
  - その phase 固有の入力と結果

### 5.2 persisted form で最低限必要なもの

- `run_ref`
- `phase`
- `timestamp`
- `review_target`
- `source_descriptor`
- `scope_snapshot`
- `verification_summary` または `blocked_diagnosis`
- `review_disposition` (parent review の場合)
- `follow_up_child_fingerprints` (follow-up child write を行った場合)
- `scheduler_blocked_outcome` (phase start 前に blocked になった場合)

### 5.3 初期 persist 境界

persist 境界は次の 2 層で固定する。

- run-level evidence
  - `task_ref`
  - 最新の canonical `review_target`
  - 最新の canonical `source_descriptor`
  - 最新の canonical `scope_snapshot`
  - `artifact_owner`
- phase-level evidence
  - `phase`
  - `timestamp`
  - phase 実行時の `source_descriptor`
  - phase 実行時の `scope_snapshot`
  - `verification_summary` または `blocked_diagnosis`

`EvidenceRecord` は run 配下 entity とし、phase-level evidence を append-only に保持する。

## 6. `review_target_commit`

`review_target_commit` は公開 phase key ではなく internal evidence として扱う。

### 6.1 保持目的

- 同じ review の再試行か、新しい implementation 結果の review かを区別する
- blocked 時に期待 commit と current workspace head の差分を説明する
- merge / verification の入力 commit を再現する

### 6.2 V2 での位置づけ

- 単独の scalar ではなく `ReviewTarget` value object の一部として扱う
- commit 単体ではなく `base/head` の対として意味づける

## 7. Rerun Diagnosis

rerun 時に判定したいこと:

- stale workspace か
- stale evidence か
- 同じ phase の再試行でよいか
- 新しい implementation を要求すべきか
- operator 判断が必要か

### 7.1 rerun 判定に使う evidence

最低限:

- current `source_descriptor`
- last successful `source_descriptor`
- current `review_target`
- last `review_target`
- `scope_snapshot`
- `artifact_owner.snapshot_version`

### 7.2 representative decisions

- `same_phase_retry`
  - source と evidence が同じ意図を指している
- `requires_new_implementation`
  - review target や source head が変わり、再試行ではなく新しい変更として扱うべき
- `requires_operator_action`
  - evidence だけでは正しい再開方法を一意に決められない
- `terminal_noop`
  - evidence 上、再実行する意味がない

## 8. Blocked Diagnosis Bundle

blocked 調査は次の canonical bundle を前提にする。

### 8.1 minimum bundle

- `task_ref`
- `run_ref`
- `phase`
- `outcome`
- `review_target`
- `source_descriptor`
- `scope_snapshot`
- `artifact_owner`
- `expected_state`
- `observed_state`
- `failing_command`
- `diagnostic_summary`
- `infra_diagnostics`

### 8.2 expected vs observed

blocked 調査で重要なのは、単にコマンドが落ちた事実ではなく、

- 何を期待していたか
- 実際には何が見えていたか

を evidence から再構成できることである。

### 8.3 domain outcome と infra diagnostic の境界

blocked bundle では、domain と infra の情報を混ぜずに並べて保持する。

- `outcome`
  - domain が意味づけした結果
  - 例: `blocked`
- `failing_command`, `observed_state`, `diagnostic_summary`
  - infra/application が観測した診断情報

`diagnostic_summary` は domain outcome そのものではなく、outcome を説明する補助診断として扱う。
これにより、`launch_failed` や `schema_validation_error` のような実装寄りの語を domain outcome に戻さずに済む。

初期方針として:

- `diagnostic_summary`
  - operator 向けの短い要約
  - rerun / unblock 判断に必要な意味だけを含む
- `infra_diagnostics`
  - stderr, exception type, failing path, observed command などの実装寄り観測値
  - domain outcome の代替には使わない

## 9. Workspace/Evidence 接続

`3025` で残した TODO として、runtime workspace と ticket workspace の責務境界がある。
evidence 側では、その曖昧さを次で抑える。

- `workspace_kind` を `SourceDescriptor` に必ず含める
- `ticket_workspace` と `runtime_workspace` を同じ `source_descriptor` に押し込めない
- application は workspace 切替時に必ず新しい `SourceDescriptor` を生成する

### 9.1 `SourceDescriptor` と `ScopeSnapshot` の persist ルール

二重保持を避けるため、保存時の責務を次で固定する。

- `SourceDescriptor`
  - workspace 種別
  - source 種別
  - ref/commit 入力
- `ScopeSnapshot`
  - edit / verification / ownership の active scope

同じ repo 名や task ref を双方へ重複複写しない。
共通参照が必要な場合は `run_ref` と `phase` を join key とする。

## 10. Scope 情報の保持

`repo scope` の意味を後から曖昧にしないため、evidence 上は umbrella 語ではなく分解した状態で保持する。

- `edit_scope`
- `verification_scope`
- `ownership_scope`

これにより、

- どの repo を編集対象として見ていたか
- どの repo を verification 対象として見ていたか
- どの owner 単位で artifact を扱っていたか

を phase ごとに再構成できる。

## 11. Non-Goals

この文書の範囲では、次を扱わない。

- SQLite schema の詳細
- blocked UI 表示の最終フォーマット
- stderr/stdout 全文の保存方式

ここでは「何を canonical evidence とみなすか」だけを定義する。

## 12. 後続へ渡す論点

- `3028`
  - evidence repository の初期実装
  - blocked diagnosis bundle の persisted form

TODO:

- `EvidenceRecord` を run 配下 entity としてどう永続化するかを Ruby skeleton 側で具体化する
- `SourceDescriptor` の type system をどこまで厳密にするかを実装時に決める

## 13. この文書の完了条件

- canonical evidence set が定義されている
- `review_target` と `source_descriptor` の persisted form が定義されている
- rerun 判定に使う evidence が定義されている
- blocked diagnosis bundle の minimum set が定義されている
- `edit_scope / verification_scope / ownership_scope` を分けて保持する方針が定義されている
