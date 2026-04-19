# A2O Design Map

対象読者: A2O 設計者 / 実装者 / reviewer
文書種別: 設計導線

この文書は、A2O の設計資料が何を扱うかと、どの順序で読むかを示す。

## 目的

- domain / application / infrastructure / project surface の責務境界を固定する。
- project 固有の rescue 分岐や workspace 依存を Engine core へ持ち込まない。
- 利用者向け surface と内部互換名の境界を明確にする。
- reference product suite を core validation の正本にする。

## 設計資料一覧

### 0. 利用者導線

- [90-user-quickstart.md](90-user-quickstart.md)

`90` は A2O を導入する利用者向けのマニュアルである。

### 1. 実装規律

- [05-engineering-rulebook.md](05-engineering-rulebook.md)

immutable、TDD、リファクタリング、必要修正から逃げないことを固定する。

### 2. 用語と bounded context

- [10-bounded-context-and-language.md](10-bounded-context-and-language.md)

task kind、phase、workspace、repo slot、evidence などの用語を固定する。

### 3. core domain model

- [20-core-domain-model.md](20-core-domain-model.md)

aggregate / entity / value object と状態遷移を扱う。

### 4. workspace / repo-slot / lifecycle

- [30-workspace-and-repo-slot-model.md](30-workspace-and-repo-slot-model.md)

fixed repo slot、同期方針、freshness、retention、GC、merge workspace を扱う。

### 5. project surface / presets

- [40-project-surface-and-presets.md](40-project-surface-and-presets.md)
- [42-single-file-project-package-schema.md](42-single-file-project-package-schema.md)
- [64-runtime-extension-boundary.md](64-runtime-extension-boundary.md)

project package schema、project 固有 command、repo slot、verification、bootstrap hook の境界を扱う。

### 6. evidence / rerun / blocked diagnosis

- [50-evidence-and-rerun-diagnosis.md](50-evidence-and-rerun-diagnosis.md)

review / merge / rerun / blocked 調査の再現性を支える内部 evidence を扱う。

### 7. runtime distribution

- [60-container-distribution-and-project-runtime.md](60-container-distribution-and-project-runtime.md)
- [62-agent-worker-gateway-design.md](62-agent-worker-gateway-design.md)
- [66-runtime-naming-boundary.md](66-runtime-naming-boundary.md)

Docker runtime image、host launcher、bundled kanban service、agent gateway、内部互換名の境界を扱う。

### 8. reference validation

- [68-reference-product-suite.md](68-reference-product-suite.md)

core validation で使う sample product と、release validation の対象範囲を扱う。

### 9. implementation status

- [70-implementation-status.md](70-implementation-status.md)

0.5.0 release 時点の公開 surface と検証状態を扱う。
