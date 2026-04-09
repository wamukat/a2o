# A3-v2

対象読者: A3-v2 実装者 / 設計者 / reviewer
文書種別: リポジトリ入口

このディレクトリは、A3-v2 の実装と設計資料を集約するための作業場所である。
既存の `a3-engine` とは分けて扱い、この配下で独立した実装を育てる。

## 方針

- A3-v2 は V1 の局所修正の延長ではなく、新しい製品として設計する
- DDD を強く意識し、domain knowledge を中心へ集約する
- project 固有知識は最小 injection surface と preset/template で表現する
- workspace / rerun / blocked recovery の複雑性を、domain model と evidence model で抑える
- ルート名は `a3-v2` のままでよいが、配下では `v2` を重ねず `a3` を使う

## 読み順

1. [docs/00-design-map.md](/Users/takuma/workspace/mypage-prototype/a3-v2/docs/00-design-map.md)
2. [docs/05-engineering-rulebook.md](/Users/takuma/workspace/mypage-prototype/a3-v2/docs/05-engineering-rulebook.md)
3. [docs/10-bounded-context-and-language.md](/Users/takuma/workspace/mypage-prototype/a3-v2/docs/10-bounded-context-and-language.md)
4. [docs/20-core-domain-model.md](/Users/takuma/workspace/mypage-prototype/a3-v2/docs/20-core-domain-model.md)
5. [docs/30-workspace-and-repo-slot-model.md](/Users/takuma/workspace/mypage-prototype/a3-v2/docs/30-workspace-and-repo-slot-model.md)
6. [docs/40-project-surface-and-presets.md](/Users/takuma/workspace/mypage-prototype/a3-v2/docs/40-project-surface-and-presets.md)
7. [docs/50-evidence-and-rerun-diagnosis.md](/Users/takuma/workspace/mypage-prototype/a3-v2/docs/50-evidence-and-rerun-diagnosis.md)
8. [docs/60-container-distribution-and-project-runtime.md](/Users/takuma/workspace/mypage-prototype/a3-v2/docs/60-container-distribution-and-project-runtime.md)

## ソースツリー

- `bin/a3`
- `lib/a3/`
  - `domain/`
  - `application/`
  - `infra/`
  - `adapters/`
  - `cli/`
- `spec/`

配下の命名では `a3_v2` や `v2` を使わず、実装上の中心モジュール名は `A3` とする。

## 対応チケット

- `A3-v2#3022` DDD-based foundations umbrella
- `A3-v2#3023` bounded contexts and ubiquitous language
- `A3-v2#3024` core domain model and state transitions
- `A3-v2#3025` workspace and repo-slot lifecycle model
- `A3-v2#3026` minimal project surface and presets
- `A3-v2#3027` evidence and rerun diagnosis model
- `A3-v2#3028` Ruby skeleton with DDD layer boundaries

## 参照元

- [A3-2 Product Specification](/Users/takuma/workspace/mypage-prototype/docs/10-ops/10-08-a3-2-product-spec.md)
- [A3 Parent-Child Stabilization Plan](/Users/takuma/workspace/mypage-prototype/docs/10-ops/10-06-a3-parent-child-stabilization-plan.md)
- [Issue Workspace Worktree Migration Design](/Users/takuma/workspace/mypage-prototype/a3-engine/docs/issue-workspace-worktree-migration-design.md)
