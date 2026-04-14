# A3 Design Map

対象読者: A3 設計者 / 実装者
文書種別: 設計導線

この文書は、A3 の設計資料が何を扱うかと、どの順序で読むかを示す。

## 目的

- DDD を前提に、domain / application / infrastructure / project surface の責務境界を先に固定する
- 旧実装の局所的な rescue 分岐や workspace 依存を、current A3 へ持ち込まない
- 後続の Ruby 実装が、設計書に従って自然に分割されるようにする

## 設計資料一覧

### 0. 実装規律

- [05-engineering-rulebook.md](05-engineering-rulebook.md)

ここでは immutable、TDD、リファクタリング、必要修正から逃げないことを固定する。

### 1. 用語と bounded context

- [10-bounded-context-and-language.md](10-bounded-context-and-language.md)
- 対応 ticket: `A3-v2#3023`

ここでは task kind、phase、workspace、repo slot、evidence などの用語を固定する。

### 2. core domain model

- [20-core-domain-model.md](20-core-domain-model.md)
- 対応 ticket: `A3-v2#3024`

ここでは aggregate / entity / value object と状態遷移を扱う。

### 3. workspace / repo-slot / lifecycle

- [30-workspace-and-repo-slot-model.md](30-workspace-and-repo-slot-model.md)
- [35-repo-worktree-and-merge-flow-diagrams.md](35-repo-worktree-and-merge-flow-diagrams.md)
- 対応 ticket: `A3-v2#3025`

ここでは fixed repo slot、同期方針、freshness、retention、GC に加え、repo / worktree / merge model を扱う。
repo slot ごとの ref、merge workspace、publish 完了条件まで追いたい場合は `35` を読む。

### 4. project surface / presets

- [40-project-surface-and-presets.md](40-project-surface-and-presets.md)
- 対応 ticket: `A3-v2#3026`

ここでは PJ 注入面の最小集合と preset/template を扱う。

### 5. evidence / rerun / blocked diagnosis

- [50-evidence-and-rerun-diagnosis.md](50-evidence-and-rerun-diagnosis.md)
- 対応 ticket: `A3-v2#3027`

ここでは review / merge / rerun / blocked 調査の再現性を支える内部 evidence を扱う。

### 6. container distribution / project runtime packaging

- [60-container-distribution-and-project-runtime.md](60-container-distribution-and-project-runtime.md)
- [66-runtime-naming-boundary.md](66-runtime-naming-boundary.md)

ここでは A3 を Docker image として配布し、案件ごとの runtime package と永続 state をどう分離するかを扱う。
`66` では current public surface の `runtime` 用語と、内部互換として残る `scheduler` 用語の境界を扱う。

### 7. implementation status

- [70-implementation-status.md](70-implementation-status.md)

ここでは future A3Engine base に seed された current implementation status を追う。

### 8. engine redesign

- [75-engine-redesign.md](75-engine-redesign.md)

ここでは engine redesign の設計方針を追う。

### 9. cutover plan

- [80-a3engine-reseed-and-naming-cutover-plan.md](80-a3engine-reseed-and-naming-cutover-plan.md)

ここでは `a3-engine-legacy` 退避、新 `a3-engine` seed、naming cutover の実行計画を追う。

### 10. user quickstart

- [90-user-quickstart.md](90-user-quickstart.md)

ここでは A3 release を受け取る利用者が、project package と短い runtime command で A3 を使うための入口を扱う。

## 実装前提

- Ruby 実装は、上記 1-5 が揃ってから本格着手する
- `A3-v2#3028` は設計をコードへ落とす初手として扱う
- 設計未確定のまま orchestration コードを書き始めない
