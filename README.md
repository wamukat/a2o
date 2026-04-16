# A3 Engine

対象読者: A3 実装者 / 設計者 / reviewer / operator
文書種別: リポジトリ入口

このディレクトリは current A3 Engine の本体実装と設計資料を集約する。旧 `a3-v2/` source tree は削除済みであり、現在の正本はこの `a3-engine` と workspace root の `scripts/a3` / `Taskfile.yml` である。

## 方針

- A3 は V1 の局所修正の延長ではなく、bundled kanban service と `a3-agent` を前提にした current runtime として扱う
- A3 本体は orchestration / scheduler / state / kanban adapter / agent control plane を持つ
- project 固有 toolchain は A3 image へ bake せず、host または dev-env container に置いた `a3-agent` が実行する
- project 固有知識は最小 injection surface と preset/template で表現する
- workspace / rerun / blocked recovery の複雑性を、domain model と evidence model で抑える

## 読み順

1. [docs/00-design-map.md](/Users/takuma/workspace/mypage-prototype/a3-engine/docs/00-design-map.md)
2. [docs/05-engineering-rulebook.md](/Users/takuma/workspace/mypage-prototype/a3-engine/docs/05-engineering-rulebook.md)
3. [docs/10-bounded-context-and-language.md](/Users/takuma/workspace/mypage-prototype/a3-engine/docs/10-bounded-context-and-language.md)
4. [docs/20-core-domain-model.md](/Users/takuma/workspace/mypage-prototype/a3-engine/docs/20-core-domain-model.md)
5. [docs/30-workspace-and-repo-slot-model.md](/Users/takuma/workspace/mypage-prototype/a3-engine/docs/30-workspace-and-repo-slot-model.md)
6. [docs/40-project-surface-and-presets.md](/Users/takuma/workspace/mypage-prototype/a3-engine/docs/40-project-surface-and-presets.md)
7. [docs/50-evidence-and-rerun-diagnosis.md](/Users/takuma/workspace/mypage-prototype/a3-engine/docs/50-evidence-and-rerun-diagnosis.md)
8. [docs/60-container-distribution-and-project-runtime.md](/Users/takuma/workspace/mypage-prototype/a3-engine/docs/60-container-distribution-and-project-runtime.md)
9. [docs/68-reference-product-suite.md](docs/68-reference-product-suite.md)
10. [docs/70-implementation-status.md](/Users/takuma/workspace/mypage-prototype/a3-engine/docs/70-implementation-status.md)

## 配布 / runtime

current packaging は `docker:a3 + bundled kanban service + Go a3-agent` の compose 形状を標準にする。kanban service は A3 image に内包せず、compose 上の service として扱う。現行 default provider は SoloBoard である。A3 Engine は Docker runtime command として提供し、host へ Ruby interpreter を要求しない。project command は host または dev-env container に install した Go release binary の `a3-agent` が pull 実行する。

Core validation は Portal ではなく、A2O 専用 reference product suite を正本にする。Portal は実プロダクト integration validation として扱う。詳細は [docs/68-reference-product-suite.md](docs/68-reference-product-suite.md) を参照する。

代表入口:

- `task a3:portal:bundle:up`
- `task a3:portal:bundle:bootstrap`
- `task a3:portal:bundle:doctor`
- `task a3:portal:bundle:agent-loop`
- `task a3:portal:bundle:observe`

`task a3:portal:bundle:run-once` は legacy direct-path diagnosis 用であり、通常検証には使わない。

## 実装位置

- A3 本体実装: `lib/a3/`, `bin/a3`, `spec/` (`bin/a3` は Docker runtime 内の engine command)
- Go agent: `agent-go/`
- Docker runtime assets: `docker/` (`docker/a3-runtime/Dockerfile` exposes `/usr/local/bin/a3` inside the image)
- 設計 / 進捗正本: `docs/60-container-distribution-and-project-runtime.md`, `docs/70-implementation-status.md`

## 参照元

- [A3-2 Product Specification](/Users/takuma/workspace/mypage-prototype/docs/10-ops/10-08-a3-2-product-spec.md)
- [A3 Parent-Child Stabilization Plan](/Users/takuma/workspace/mypage-prototype/docs/10-ops/10-06-a3-parent-child-stabilization-plan.md)
- [A3 Cutover Decision Ledger](/Users/takuma/workspace/mypage-prototype/docs/10-ops/10-04-a3-cutover-decision-ledger.md)
