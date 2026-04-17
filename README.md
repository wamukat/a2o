# A2O Engine

対象読者: A2O 利用者 / 実装者 / reviewer / operator
文書種別: リポジトリ入口

A2O は kanban 上の task を読み取り、作業用 workspace、agent 実行、検証、merge、evidence 記録までを管理する automation engine である。

このリポジトリは A2O Engine 本体、Go host launcher、Go agent、Docker runtime image、reference product package、設計資料を含む。通常利用者向けの入口は `a2o`、`a2o-agent`、project package、bundled kanban service である。

## 方針

- A2O は bundled kanban service と `a2o-agent` を前提にした runtime として扱う。
- A2O Engine は orchestration、state、kanban adapter、agent control plane、evidence を持つ。
- project 固有 toolchain は runtime image に bake せず、host または dev-env に置いた `a2o-agent` が実行する。
- project 固有知識は project package で宣言し、Engine core へ埋め込まない。
- core validation は `reference-products/` の小さな複数プロダクトで行う。

## 読み順

1. [docs/90-user-quickstart.md](docs/90-user-quickstart.md)
2. [docs/68-reference-product-suite.md](docs/68-reference-product-suite.md)
3. [docs/60-container-distribution-and-project-runtime.md](docs/60-container-distribution-and-project-runtime.md)
4. [docs/00-design-map.md](docs/00-design-map.md)
5. [docs/70-implementation-status.md](docs/70-implementation-status.md)

## 代表入口

```sh
a2o host install
a2o project bootstrap --package ./reference-products/typescript-api-web/project-package
a2o kanban up
a2o kanban doctor
a2o kanban url
a2o agent install --target auto --output ./.work/a2o-agent/bin/a2o-agent
```

runtime image の中では `bin/a3` が Engine CLI として残る。これは内部互換名であり、利用者向けの正規入口は `a2o` と `a2o-agent` である。公開名称と内部互換名の境界は [docs/92-a2o-public-branding-boundary.md](docs/92-a2o-public-branding-boundary.md) にまとめる。

## 実装位置

- Engine core: `lib/a3/`, `bin/a3`, `spec/`
- Host launcher / agent: `agent-go/`
- Docker runtime assets: `docker/`
- Kanban tooling: `tools/kanban/`
- Reference product packages: `reference-products/`
- 利用者マニュアル: [docs/90-user-quickstart.md](docs/90-user-quickstart.md)

## Validation

reference product suite は次の 4 パターンを持つ。

- `reference-products/typescript-api-web/`
- `reference-products/go-api-cli/`
- `reference-products/python-service/`
- `reference-products/multi-repo-fixture/`

各 product は `project-package/` を持ち、`a2o project bootstrap --package <package>` で runtime instance を作成できる。suite の目的と現行 baseline は [docs/68-reference-product-suite.md](docs/68-reference-product-suite.md) と [docs/69-reference-runtime-baseline.md](docs/69-reference-runtime-baseline.md) を参照する。
