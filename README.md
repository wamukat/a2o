# A3 Engine

対象読者: A3 実装者 / 設計者 / reviewer / operator
文書種別: リポジトリ入口

このリポジトリは current A2O/A3 Engine の本体実装と設計資料を集約する。旧 `a3-v2/` source tree と Portal workspace-local Taskfile runtime entrypoint は削除済みであり、現在の通常利用者向け正本は Go host launcher `a2o`、Docker runtime image、`a2o-agent`、project package である。

## 方針

- A3 は V1 の局所修正の延長ではなく、bundled kanban service と `a2o-agent` を前提にした current runtime として扱う
- A3 本体は orchestration / scheduler / state / kanban adapter / agent control plane を持つ
- project 固有 toolchain は A3 image へ bake せず、host または dev-env container に置いた `a2o-agent` が実行する
- project 固有知識は最小 injection surface と preset/template で表現する
- workspace / rerun / blocked recovery の複雑性を、domain model と evidence model で抑える

## 読み順

1. [docs/00-design-map.md](docs/00-design-map.md)
2. [docs/05-engineering-rulebook.md](docs/05-engineering-rulebook.md)
3. [docs/10-bounded-context-and-language.md](docs/10-bounded-context-and-language.md)
4. [docs/20-core-domain-model.md](docs/20-core-domain-model.md)
5. [docs/30-workspace-and-repo-slot-model.md](docs/30-workspace-and-repo-slot-model.md)
6. [docs/40-project-surface-and-presets.md](docs/40-project-surface-and-presets.md)
7. [docs/50-evidence-and-rerun-diagnosis.md](docs/50-evidence-and-rerun-diagnosis.md)
8. [docs/60-container-distribution-and-project-runtime.md](docs/60-container-distribution-and-project-runtime.md)
9. [docs/68-reference-product-suite.md](docs/68-reference-product-suite.md)
10. [docs/70-implementation-status.md](docs/70-implementation-status.md)

## 配布 / runtime

current packaging は `docker:a3 + bundled kanban service + Go a2o-agent` の compose 形状を標準にする。kanban service は A3 image に内包せず、compose 上の service として扱う。現行 default provider は SoloBoard である。A3 Engine は Docker runtime command として提供し、host へ Ruby interpreter を要求しない。project command は host または dev-env container に install した Go release binary の `a2o-agent` が pull 実行する。内部実装名としての `a3-agent` は互換名であり、通常利用者向け surface では `a2o-agent` を使う。

Core validation は Portal ではなく、A2O 専用 reference product suite を正本にする。Portal は実プロダクト integration validation として扱う。詳細は [docs/68-reference-product-suite.md](docs/68-reference-product-suite.md) を参照する。

代表入口:

- `a2o host install`
- `a2o project bootstrap --package <reference-product-package>`
- `a2o kanban up`
- `a2o kanban doctor`
- `a2o kanban url`
- `a2o agent install`

Reference product suite の package / validation scenario は `reference-products/` と [docs/68-reference-product-suite.md](docs/68-reference-product-suite.md) を正本にする。Portal workspace-local の旧 Taskfile 互換入口は通常の A2O core validation には使わず、Portal integration validation または historical diagnosis の文脈に限定する。

## 実装位置

- A3 本体実装: `lib/a3/`, `bin/a3`, `spec/` (`bin/a3` は Docker runtime 内の engine command)
- Go agent: `agent-go/`
- Docker runtime assets: `docker/` (`docker/a3-runtime/Dockerfile` exposes `/usr/local/bin/a3` inside the image)
- Reference product packages: `reference-products/`
- 設計 / 進捗正本: `docs/60-container-distribution-and-project-runtime.md`, `docs/70-implementation-status.md`

## 参照元

- Historical product/design notes live outside this repository. They are provenance, not current operator runbooks.
