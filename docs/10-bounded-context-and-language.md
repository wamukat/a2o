# A3 Bounded Context and Ubiquitous Language

対象読者: A3 設計者 / 実装者 / reviewer
文書種別: 設計メモ
対応 ticket: `A3-v2#3023` (historical ref)

この文書は、A3 の用語と bounded context を先に固定するためのもの。
後続の core domain model、workspace model、evidence model、Ruby 実装は、この文書の語彙と境界を前提にする。

## 1. 目的

- V1 で起きた「同じ概念を別の場所で別名・別意味で持つ」状態を避ける
- domain knowledge を 1 か所へ寄せる前提として、用語と責務を固定する
- `review`, `verification`, `workspace`, `evidence` などの意味を先に確定し、後続の設計と実装のぶれを防ぐ

## 2. 設計姿勢

A3 では、用語を「コードの都合」ではなく「ドメインの意味」で定義する。

- 先に意味を固定し、その後で class/module/file 名を合わせる
- phase ごとの便宜的な救済分岐を domain language に持ち込まない
- 旧 A3 の `inspection` や `integration_judgment` のような語は、必要なら移行メモにだけ残し、A3 の主要語彙には採用しない

## 3. Context Map

現時点では、A3 の主要 context を次の 4 つに分ける。

### 3.1 Task Execution Context

扱うもの:

- task kind
- phase
- run
- terminal outcome
- rerun eligibility

責務:

- task が今どの段階にいるかを表す
- 次に何が起きるかを rule として持つ

持たないもの:

- Git 実行
- subprocess 実行
- filesystem 操作

### 3.2 Workspace Management Context

扱うもの:

- workspace
- repo slot
- lifecycle
- synchronization strategy
- retention / GC

責務:

- ticket ごとの作業面をどう保持し、いつ同期し、いつ回収するかを表す

持たないもの:

- review の採否判断
- rerun の意味判断

### 3.3 Evidence and Diagnosis Context

扱うもの:

- review target
- source descriptor
- verification summary
- blocked diagnosis metadata
- rerun diagnosis

責務:

- review / verification / merge / rerun / blocked 調査の再現性を保つ

持たないもの:

- Git checkout や clone の実処理
- phase orchestration

### 3.4 Project Surface Context

扱うもの:

- skill
- verification commands
- remediation commands
- workspace hook
- preset / template

責務:

- PJ 固有要件を最小 surface で表現する

持たないもの:

- task state rule
- workspace lifecycle rule
- rerun rule

## 4. Context 間の依存

依存方向は次で固定する。

- `Task Execution` -> `Workspace Management`
- `Task Execution` -> `Evidence and Diagnosis`
- `Task Execution` -> `Project Surface`
- `Workspace Management` -> `Evidence and Diagnosis`

逆依存は持たせない。

特に:

- `Project Surface` は domain rule を上書きしない
- `Workspace Management` は task outcome を決めない
- `Evidence and Diagnosis` は phase を起動しない

## 5. Ubiquitous Language

### 5.1 Task

A3 が管理する実行単位。kanban task に対応するが、単なる外部 ID ではなく、kind・status・phase history を持つ domain object として扱う。

### 5.2 Task Kind

task の責務種別。

- `single`
  - 単独で `implementation -> verification -> merge-to-live` を進む
- `child`
  - parent integration branch へ統合され、current canonical flow では `implementation -> verification -> merge-to-parent` を進む
- `parent`
  - 子成果を束ねて `review -> verification -> merge-to-live` を行う

`repo:alpha` や `repo:beta` は task kind ではない。これは repo scope / ownership 側の情報である。

### 5.3 Phase

task 実行の正規段階。

- `implementation`
  - 変更を生む
- `review`
  - parent が子成果の統合判断を行う
- `verification`
  - deterministic gate を実行する
- `merge`
  - target branch へ統合する

V2 では `inspection` を主要語彙に採用しない。必要なら移行メモでのみ扱う。

### 5.4 Review

parent にだけ残る AI 判断フェーズ。script 実行の有無ではなく、「子成果を束ねた統合判断を行う」ことが本質である。

- parent `review`
  - child merge 済み integration branch に対して包括レビューする

single / child では `review` は独立 phase としては扱わず、implementation evidence の中に self-review clean / findings fix の証跡を保持する。

### 5.5 Verification

deterministic gate を実行するフェーズ。AI の包括判断を再度行う場ではない。

- 入力は phase 開始前に固定される
- 合格条件は PJ 注入の commands / gates で決まる
- parent `verification` は child 採否判断を持たない

### 5.6 Merge

source を target へ統合するフェーズ。`merge` は review の延長ではなく、branch / commit を扱う独立フェーズとして扱う。

### 5.7 Run

特定 task に対する 1 回の phase 実行単位。worker invocation と完全一致しなくてもよいが、operator から見て追跡可能な実行記録として一意であることが必要。

### 5.8 Outcome

run または phase の帰結。

最低限:

- `completed`
- `blocked`
- `retryable`
- `terminal_noop`

詳細な分類は `20-core-domain-model.md` 側で定義する。

### 5.9 Workspace

ticket ごとに独立した作業面。live repo と分離され、review / verification / merge でも同じ topology を前提にする。

### 5.10 Repo Slot

workspace 内の固定 repo path。

重要なのは次の分離である。

- repo slot
  - path / existence guarantee
- repo scope
  - editability / ownership / verification scope

`repo slot` は「ここに repo が存在すること」を表し、`repo scope` は「どの repo を編集対象として扱うか」を表す。

### 5.11 Repo Scope

task が編集責務や verification scope を持つ repo の集合。`repo:alpha`, `repo:beta`, `repo:both` はこの領域に属する。

### 5.12 Integration Branch

parent-child topology において、child 成果を集約する branch。parent `review` と parent `verification` の入力源になる。

### 5.13 Review Target

review worker が監査対象として見た変更セットを再現するための内部概念。公開 API の中心キーではない。

### 5.14 Evidence

review / verification / merge / rerun / blocked 調査の再現性を支える内部証跡。

### 5.15 Artifact Owner

workspace とは独立した artifact キャッシュや runtime 生成物の ownership 単位。path ではなく owner identity を表す。

## 6. Parent と Child の責務境界

### Child

- 自分の変更を作る
- 自分の review を受ける
- 自分の verification を通す
- parent integration branch へ merge する

### Parent

- 子成果が揃った状態を review する
- integration branch を verification する
- live へ merge する

Parent は `implementation` を持たない。ここを曖昧にすると、親で子と同じ実装責務を再導入してしまう。

## 7. Domain / Application / Infrastructure / Project Surface の責務境界

### Domain

持つもの:

- task kind の意味
- phase の意味
- rerun rule
- blocked outcome rule
- evidence の意味

持たないもの:

- CLI 入出力
- SQLite アクセス
- Git 実行

### Application

持つもの:

- use case orchestration
- phase 開始/完了
- domain object の組み立て

持たないもの:

- shell command の組み立てロジックの本体
- domain rule の定義

### Infrastructure

持つもの:

- Git / worktree adapter
- filesystem
- SQLite
- subprocess runner

持たないもの:

- task transition の意味判断
- blocked の意味判断

### Project Surface

持つもの:

- skills
- commands
- hooks
- presets

持たないもの:

- phase semantics
- rerun semantics
- evidence semantics

## 8. 非採用語彙 / 避けたい表現

V2 の主要語彙としては、次を採用しない。

- `support clone`
- `bridge healing`
- `inspection` を verification の中心語として使うこと
- `integration judgment` を parent verification と混同して使うこと
- `repo が必要なら後から生やす` という発想を表す語

これらは V1 由来の運用メモとしては残りうるが、V2 の中心概念にはしない。

## 9. この文書の完了条件

- 用語ごとの意味と責務境界が定義されている
- context 間の依存方向が明示されている
- parent review と parent verification の違いが語彙レベルで固定されている
- `repo slot` と `repo scope` が分離されている
- 後続の `20-core-domain-model.md` がこの語彙だけで書ける
