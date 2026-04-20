# A2O Workspace and Repo-Slot Model

この文書は、A2O の workspace topology、repo slot、同期方針、freshness、retention/GC を固定するためのもの。
V1 の `support clone + bridge healing` を不要化し、phase ごとの path ぶれや存在判定漏れを防ぐ。

## 1. 目的

- fixed repo slot と同期コストを分離する
- phase ごとに repo の有無が変わる設計をやめる
- V1 の support clone / top-level symlink / reverse bridge 問題を再発させない
- worktree backend を前提に、path contract と freshness policy を先に固定する

## 2. 基本方針

- ticket workspace は fixed repo slot namespace を持つ
- repo slot の path contract は phase をまたいで不変
- phase ごとに repo 実体の有無を変えない
- repo の「存在保証」と「編集対象/verification 対象」の意味を分ける
- phase 開始後の `missing repo rescue` を前提にしない

## 3. Workspace Topology

### 3.1 Ticket Workspace

ticket workspace は task ごとの作業面であり、少なくとも次の固定 slot を持つ。

sample topology の初期前提:

- `repo_alpha`
- `repo_beta`

例:

```text
ticket-workspace/
  repo_alpha/
  repo_beta/
  .work/
```

重要なのは path contract であり、phase に応じて `.support/...` のような別名 path を導入しないこと。

### 3.2 Runtime Workspace

A2O では execution 専用の runtime workspace を持ちうるが、phase ごとに topology を変えない。

- ticket workspace
  - source-of-truth を保持する作業面
- runtime workspace
  - detached source から materialize された execution 面

どちらを使う場合でも repo slot namespace は揃える。

### 3.4 Ticket Workspace と Runtime Workspace の責務境界

両者は path 互換を持つが、役割は分ける。

- ticket workspace
  - task の source-of-truth を保持する
  - implementation の編集面として使う
  - commit 対象の作業面である
- runtime workspace
  - review / verification / merge の再現可能な実行面として使う
  - detached source や integration input を materialize する
  - source-of-truth 自体は持たない

初期方針として、implementation は ticket workspace、review / verification / merge は runtime workspace を既定とする。
同じ phase で両者を混在させない。

### 3.3 Repo Slot

repo slot は path と存在保証の概念であり、ownership や verification scope とは別である。

- `RepoSlot`
  - path contract
  - existence guarantee
- `EditScope`
  - 編集責務
- `VerificationScope`
  - verification 対象
- `OwnershipScope`
  - branch / artifact owner の単位

## 4. Fixed Repo Slot

### 4.1 fixed であるとは何か

fixed repo slot とは、repo 数にかかわらず「slot 名が予約される」ことを意味する。

これは次を意味しない。

- 毎回すべての repo を同じ重さで eager に fully sync すること
- phase 開始後に必要 repo を後付けで救済してよいこと

固定したいのは、あくまで path と存在保証の契約である。

### 4.2 initial availability

phase 開始前に、その phase が必要とする repo は target / non-target を問わず存在保証されていなければならない。

つまり:

- target repo
  - eager materialize してよい
- non-target repo
  - lazy でもよい
  - ただし phase 入口では ready でなければならない

## 5. Synchronization Strategy

同期方針は PJ 固有ではなく engine 側の policy として扱う。

### 5.1 sync classes

- `eager`
  - target repo
  - parent review / parent verification / merge の authoritative source となる repo
- `lazy_but_guaranteed`
  - 参照専用 repo
  - cross-repo verification で必要と判定された repo

### 5.2 update granularity

更新粒度は全 repo 一括を既定にしない。

phase 開始前に、少なくとも次を元に必要 repo を決める。

- task kind
- current phase
- edit scope
- verification scope
- source descriptor

### 5.3 phase-start guarantee

phase 入口の contract は次とする。

- phase が必要とする repo slot はすべて存在する
- source descriptor と整合する revision へ同期済みである
- application は `missing repo` を考慮して phase を開始しない

## 6. Freshness Model

workspace の再利用は freshness 判定を通った場合だけ許可する。

### 6.1 minimum inputs

少なくとも次を freshness 判定へ含める。

- source descriptor
- branch / integration descriptor
- artifact owner descriptor
- cached bootstrap marker
- workspace kind

### 6.2 mismatch policy

freshness mismatch の場合、application は次のどちらかを選ぶ。

- re-materialize
- rerun decision へ渡す

domain rule が必要な場合は、workspace 層だけで勝手に replay / rescue しない。

## 6.3 Workspace Selection Rule

application は phase 開始時に、phase と source descriptor から使用 workspace を一意に選ぶ。

初期規則:

- `implementation`
  - `ticket_workspace`
- `review`
  - `runtime_workspace`
- `verification`
  - `runtime_workspace`
- `merge`
  - `runtime_workspace`

runtime workspace を作る入力 descriptor は少なくとも次とする。

- `workspace_kind=runtime_workspace`
- `source_type`
- `ref_name` または `commit_sha`
- `task_ref`

これにより、workspace 切替は application の明示判断として扱い、workspace 層の暗黙 rescue にしない。

## 7. Artifact Owner との関係

workspace と artifact cache は同じライフサイクルにしない。

- workspace
  - task 単位
- artifact owner
  - owner 単位

初期前提:

- standalone
  - task owner
- parent-child
  - parent owner

これにより、workspace cleanup と artifact reuse を別軸で扱える。

## 7.1 Follow-Up Child Fingerprint

parent review findings から follow-up child を自動生成する場合、Kanban 側には
idempotent create+attach を行う。

Kanban CLI には task delete が無いため、`task-create` 後に relation-create が失敗しても
rollback を前提にしない。代わりに、follow-up child は deterministic fingerprint を持つ。

最低限の fingerprint 入力:

- `parent_ref`
- `review_run_ref`
- `repo_scope`
- `finding_key`

`repo_scope=both` の場合は slot ごとに fingerprint を分ける。

- `.../repo_alpha/...`
- `.../repo_beta/...`

この fingerprint は child task の title / description / operator comment に残し、
再試行時は:

1. 同 fingerprint の follow-up child を Kanban 上で探索する
2. あれば再利用する
3. なければ create する
4. relation を ensure する

これにより、partially created child を orphan のまま放置せず、次回 retry で attach へ回収できる。

### 7.2 Fingerprint Mismatch Policy

同じ fingerprint の child が既に存在しても、canonical payload と一致しない場合がある。

例:

- 手動編集で title / description / labels が変わった
- unsupported schema の child が残っている
- partial recovery の途中で comment だけ更新された

この場合の固定 rule:

- fingerprint 一致 child は「再利用候補」ではあるが、そのまま無条件 reuse しない
- writer は canonical payload との差分を検査する
- relation が無いだけなら relation を ensure して recovery 完了としてよい
- canonical payload と矛盾する場合は新規 child を追加作成せず、parent を blocked とする
- blocked comment には fingerprint と mismatch 項目を残し、operator が整理できるようにする

つまり、idempotency は「fingerprint が同じなら何でも再利用する」ではなく、
canonical payload と両立する場合にだけ reuse する。

canonical payload の比較対象は次で固定する。

- title
  - `ParentRef` と repo scope を含む deterministic title
- description
  - `review_disposition.summary`
  - `review_disposition.description`
  - `fingerprint`
- labels
  - repo scope label
  - `trigger:auto-implement`
  - follow-up child 識別 label
- parent relation
  - parent task への relation が存在すること

この比較対象以外の kanban 表示要素は mismatch 判定に使わない。

## 8. Retention and GC

### 8.1 retention

- active task の workspace は保持する
- terminal task の workspace は retention policy に従って quarantine / cleanup 対象とする
- cleanup は operator が明示実行できる command を持つ前提とし、現状は `cleanup-terminal-workspaces` が `ticket workspace` / `runtime workspace` / `quarantine` を dry-run 付きで扱う
- `Done` task の workspace cleanup と blocked 診断用 evidence retention は独立した policy とする
- disk pressure 対策として、terminal task の古い runtime workspace から優先回収できることを要求する

### 8.2 GC principle

GC の責務は「repo slot contract を壊さずに古い作業面だけを回収すること」である。

### 8.3 explicit non-goals

GC は次を目的にしない。

- blocked 調査に必要な evidence の破棄
- artifact owner cache の無差別削除
- phase 実行中 workspace の投機的 cleanup

## 9. Worktree Backend 前提

V2 は worktree backend を前提にするが、この文書の主眼は backend 実装そのものではない。

ここで固定したいのは:

- repo slot namespace
- freshness inputs
- synchronization policy
- retention / GC policy

backend 実装はこれに従う consumer である。

## 10. 非採用

V2 では次を採らない。

- `.support/...` の補助 clone
- top-level symlink bridge
- reverse bridge healing
- phase 開始後の repo 欠落救済を前提にした設計
- phase ごとに別 path topology を持つ設計

## 11. 後続へ渡す論点

次の文書/実装でさらに詰める。

- `3027`
  - freshness 判定と evidence の結合点
- `3028`
  - worktree backend の skeleton 上での具体化

TODO:

- runtime workspace と ticket workspace の責務境界を、実装時にさらに明文化する
- detached source から materialize された execution 面としての runtime workspace が、どの descriptor を入力に受けるかを固定する
- application 層が ticket workspace と runtime workspace をどの規則で切り替えるかを定義する

## 12. この文書の完了条件

- fixed repo slot と eager full materialization が分離されている
- phase 開始前の existence guarantee が定義されている
- sync class と update granularity が定義されている
- freshness inputs が定義されている
- retention / GC の方針が定義されている
- support clone / bridge healing を V2 の設計語彙から外せている
