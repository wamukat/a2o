# A3 Core Domain Model

対象読者: A3 設計者 / 実装者
文書種別: 設計メモ
対応 ticket: `A3-v2#3024` (historical ref)

この文書は、A3 の core domain model を固定するためのもの。
目的は、task / run / phase / evidence / workspace に関する知識を domain に集約し、
V1 のように executor や materializer の条件分岐へ意味が漏れないようにすることである。

## 1. 目的

- task の意味、phase の意味、outcome の意味を domain model として定義する
- rerun / blocked / merge の判断を ad-hoc な実装分岐ではなく domain rule に置く
- application 層が orchestration に専念できる形へ責務分離する

## 2. 設計方針

- domain は「何が正しいか」を持つ
- application は「どの順で進めるか」を持つ
- infrastructure は「どう実行するか」を持つ
- project surface は「PJ 固有要件をどう注入するか」を持つ

特に、次を domain へ戻す。

- phase transition の妥当性
- rerun eligibility
- blocked outcome の分類
- `review_target_commit` を含む evidence の意味
- parent / child / single の責務差

## 3. Aggregate Boundaries

### 3.1 `Task` aggregate

`Task` は A3 の中心 aggregate root とする。

持つ責務:

- task kind の保持
- current status の保持
- `EditScope` の保持
- parent/child topology の保持
- 現在どの phase を許可するかの判定

代表属性:

- `task_ref`
- `task_kind`
- `status`
- `edit_scope`
- `parent_ref`
- `child_refs`
- `current_run_ref`

### 3.2 `Run` aggregate

`Run` は task に紐づく phase execution の連続を表す aggregate root とする。

持つ責務:

- 今回の実行単位の識別
- current phase と phase history の保持
- terminal outcome の保持
- rerun eligibility の保持

代表属性:

- `run_ref`
- `task_ref`
- `current_phase`
- `phase_executions`
- `terminal_outcome`
- `rerun_decision`

`Task` と `Run` を分ける理由は、task の寿命と run の寿命が異なるからである。
同じ task が複数回 rerun されても、task identity は不変だが run identity は変わる。

## 4. Entity / Value Object

### 4.1 entity 候補

- `PhaseExecution`
  - 1 phase 分の execution 記録
- `EvidenceRecord`
  - review / verification / merge / blocked diagnosis に必要な内部証跡
- `WorkspaceSnapshot`
  - phase 開始時点の workspace / repo slot 状態

### 4.2 value object 候補

- `TaskRef`
- `RunRef`
- `TaskKind`
- `Phase`
- `Status`
- `Outcome`
- `RerunDecision`
- `RepoScope`
- `EditScope`
- `RepoSlot`
- `ReviewTarget`
- `SourceDescriptor`
- `ArtifactOwner`

value object は path や raw JSON を直接さらさず、意味ごとに小さく閉じる。

## 5. Task State Model

task status は外部 kanban status と 1 対 1 で結びつけすぎない。domain では少なくとも次を持つ。

- `todo`
- `in_progress`
- `in_review`
- `verifying`
- `merging`
- `done`
- `blocked`

外部 kanban への反映は application layer が担当する。

## 6. Phase Model

phase は次の 4 つだけを正式採用する。

- `implementation`
- `review`
- `verification`
- `merge`

`merge_recovery` は正式 phase ではない。Git merge conflict が recoverable class の場合だけ、`merge` phase 内の recovery lane として AI worker action を起動する。domain の phase order は増やさず、`merge` の terminal outcome を `completed` / `blocked` / `retryable` に分類する。

### 6.1 Single の phase order

1. `implementation`
2. `verification`
3. `merge`

### 6.2 Child の phase order

1. `implementation`
2. `verification`
3. `merge`

ただし merge target は `parent integration branch` である。

### 6.3 Parent の phase order

1. `review`
2. `verification`
3. `merge`

parent は `implementation` を持たない。

## 7. Phase Transition Rules

### 7.1 transition rule

domain は、少なくとも次を判定できる必要がある。

- ある task kind に対して、ある phase が合法か
- current outcome の後にどの phase へ進めるか
- rerun か fresh implementation か

### 7.2 representative rules

- `single`
  - `implementation completed` -> `verification`
  - `verification completed` -> `merge`
- `child`
  - `implementation completed` -> `verification`
  - `verification completed` -> `merge`
  - `merge completed` -> terminal `done`
- `parent`
  - `review completed` -> `verification`
  - `verification completed` -> `merge`

### 7.3 blocked / retry / noop

domain は少なくとも outcome を次に分ける。

- `completed`
  - 正常完了
- `blocked`
  - 人手判断や別条件が必要
- `retryable`
  - 同じ task / same intent で再試行可能
- `terminal_noop`
  - 何もする必要がなく terminal

`launch_failed` や `schema_validation_error` のような実装寄りの語は domain outcome にしない。
それらは infra/application 由来の観測値として残しても、domain では意味づけし直す。

### 7.4 Parent Review Disposition

parent review completion は boolean の `rework_required` ではなく、
canonical な `review_disposition` で扱う。

最低限の shape:

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

意味:

- `completed`
  - parent review はそのまま `verification` へ進む
- `follow_up_child`
  - parent 自身を implementation へ戻さず、新しい follow-up child を作る
- `blocked`
  - unresolved / cross-repo / operator judgment required のため parent を blocked とする

固定 rule:

- parent は `review -> rework -> in_progress -> implementation` へ戻らない
- `follow_up_child` は slot-scoped repo 修正だけに使う
- `repo_scope=unresolved` は child 自動生成せず parent blocked に落とす
- invalid / partial disposition payload は scheduler crash ではなく parent blocked として扱う

### 7.5 Parent Follow-Up Child Rule

parent review findings のうち slot-scoped なものは、既存 child の reopen ではなく
**新しい follow-up child** として扱う。

固定 rule:

- 元の `Done` child は reopen しない
- follow-up child は Kanban を正本として新規作成する
- relation も Kanban 正規 API で parent に追加する
- parent は child 完了待ち状態に戻り、active child がすべて `Done` になるまで review を再開しない

これにより、`Done` child の evidence を壊さずに、parent review で見つかった追加修正を独立 task として追跡できる。

## 8. Rerun Decision Model

rerun は application の convenience ではなく domain rule として扱う。

最低限、次を判定する必要がある。

- 同じ phase の再試行でよいか
- 新しい implementation 結果を要求すべきか
- stale evidence か stale workspace か
- blocked のまま operator 判断が必要か

`RerunDecision` value object は少なくとも次を持つ。

- `same_phase_retry`
- `requires_new_implementation`
- `requires_operator_action`
- `terminal_noop`

## 9. Evidence in Domain

`review_target_commit` は internal evidence の一部として domain で意味を持つ。

### 9.1 必要な理由

- review の再現
- merge judgment の再現
- rerun 判定
- blocked 調査

### 9.2 domain 上の位置づけ

- `ReviewTarget` は value object とする
- `EvidenceRecord` は entity として `Run` 配下にぶら下げる
- `SourceDescriptor` は raw branch/path ではなく、phase 入力の意味を表す value object とする

### 9.3 保存粒度で後続に渡す論点

次は `3027` と合わせて確定する。

- `ReviewTarget` と `SourceDescriptor` をどこまで persisted form に含めるか
- `EvidenceRecord` が phase 単位か run 単位か
- blocked diagnosis bundle に最低限含める canonical set は何か

## 10. Repo Scope in Domain

`repo scope` は単なる label ではなく domain rule の一部である。

ただし、1 つの object に意味を詰め込みすぎない。

- `EditScope`
  - task が編集責務を持つ repo 集合
- `VerificationScope`
  - verification で参照・判定対象になる repo 集合
- `OwnershipScope`
  - branch / artifact owner として扱う repo 集合

現時点では `repo scope` という umbrella 語を会話上は使ってもよいが、実装では少なくとも上記 3 種へ分解可能であるべきとする。
これにより、V1 のように「repo label の意味が phase ごとに変わる」事態を避ける。

## 11. Domain Services 候補

必要なら、次のような domain service を導入する。

- `PhaseTransitionPolicy`
- `RerunPolicy`
- `OutcomeClassifier`
- `ReviewTargetResolver`

ただし、service は entity/aggregate に置くべき知識まで吸い上げない。
まず aggregate/value object で閉じるかを優先する。

## 12. Application / Infrastructure へ渡すもの

domain が外へ渡すのは、意味づけ済みの descriptor に限定する。

例:

- `next_phase`
- `rerun_decision`
- `source_descriptor`
- `review_target`
- `verification_scope`

application / infrastructure は、これを受けて実際の command や Git 操作へ変換する。

## 13. この文書の完了条件

- aggregate root と主要 entity/value object の候補が定義されている
- task kind ごとの phase order が定義されている
- blocked / retry / noop の domain outcome が定義されている
- `review_target_commit` と `source descriptor` の domain 上の位置づけが明記されている
- `EditScope / VerificationScope / OwnershipScope` を別概念として扱う見通しがある
