# A2O Engine

A2O の正式名称は Agentic AI Orchestrator である。A2O は kanban 上の task を読み取り、作業用 workspace、agent 実行、検証、merge、evidence 記録までを管理する automation engine である。

![A2O システム概観](docs/assets/a2o-system-overview.ja.svg)

このリポジトリは A2O Engine 本体、Go host launcher、Go agent、Docker runtime image、reference product package、設計資料を含む。通常利用者向けの入口は `a2o`、`a2o-agent`、project package、bundled kanban service である。

## 基本の流れ

A2O の通常利用は次の流れで進む。

1. 利用者が `project.yaml` と AI 用 skill files を用意する。
2. 利用者が kanban に task を作る。
3. A2O Engine の scheduler が runnable task を選ぶ。
4. A2O Engine が task / project config / skill から phase job を組み立てる。
5. `a2o-agent` が product 環境で executor command を実行する。
6. Executor が生成AIと product toolchain を使って変更を作る。
7. A2O Engine が verification、merge、evidence、kanban comment を記録する。

この関係を先に理解するには [docs/ja/user/00-overview.md](docs/ja/user/00-overview.md) を読む。

## 方針

- A2O は bundled kanban service と `a2o-agent` を前提にした runtime として扱う。
- A2O Engine は orchestration、state、kanban adapter、agent control plane、evidence を持つ。
- project 固有 toolchain は runtime image に bake せず、host または dev-env に置いた `a2o-agent` が実行する。
- project 固有知識は project package で宣言し、Engine core へ埋め込まない。
- core validation は `reference-products/` の小さな複数プロダクトで行う。

## 読み順

利用者向けドキュメント:

1. [docs/ja/user/00-overview.md](docs/ja/user/00-overview.md)
2. [docs/ja/user/10-quickstart.md](docs/ja/user/10-quickstart.md)
3. [docs/ja/user/20-project-package.md](docs/ja/user/20-project-package.md)
4. [docs/ja/user/30-operating-runtime.md](docs/ja/user/30-operating-runtime.md)
5. [docs/ja/user/40-troubleshooting.md](docs/ja/user/40-troubleshooting.md)
6. [docs/ja/user/50-parent-child-task-flow.md](docs/ja/user/50-parent-child-task-flow.md)
7. [docs/ja/user/80-current-release-surface.md](docs/ja/user/80-current-release-surface.md)
8. [docs/ja/user/90-project-package-schema.md](docs/ja/user/90-project-package-schema.md)
9. [docs/ja/user/95-runtime-naming-boundary.md](docs/ja/user/95-runtime-naming-boundary.md)

開発者向けドキュメント:

1. [docs/ja/dev/00-architecture.md](docs/ja/dev/00-architecture.md)
2. [docs/ja/dev/10-engineering-rulebook.md](docs/ja/dev/10-engineering-rulebook.md)
3. [docs/ja/dev/20-bounded-context-and-language.md](docs/ja/dev/20-bounded-context-and-language.md)
4. [docs/ja/dev/30-core-domain-model.md](docs/ja/dev/30-core-domain-model.md)
5. [docs/ja/dev/40-workspace-and-repo-slot-model.md](docs/ja/dev/40-workspace-and-repo-slot-model.md)
6. [docs/ja/dev/50-project-surface.md](docs/ja/dev/50-project-surface.md)
7. [docs/ja/dev/60-evidence-and-rerun-diagnosis.md](docs/ja/dev/60-evidence-and-rerun-diagnosis.md)
8. [docs/ja/dev/70-agent-worker-gateway-design.md](docs/ja/dev/70-agent-worker-gateway-design.md)
9. [docs/ja/dev/80-runtime-extension-boundary.md](docs/ja/dev/80-runtime-extension-boundary.md)
10. [docs/ja/dev/90-reference-product-suite.md](docs/ja/dev/90-reference-product-suite.md)
11. [docs/ja/dev/95-kanban-adapter-boundary.md](docs/ja/dev/95-kanban-adapter-boundary.md)

## 代表入口

```sh
a2o host install
a2o upgrade check
a2o project template --with-skills --output ./project-package/project.yaml
a2o worker scaffold --language python --output ./project-package/commands/a2o-worker.py
a2o worker validate-result --request request.json --result result.json
a2o project bootstrap --package ./reference-products/typescript-api-web/project-package
a2o project lint --package ./reference-products/typescript-api-web/project-package
a2o project validate --package ./reference-products/typescript-api-web/project-package --config project-test.yaml
a2o kanban up
a2o kanban doctor
a2o kanban url
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
a2o runtime run-once
a2o runtime run-once --project-config project-test.yaml
a2o runtime start
a2o runtime status
a2o runtime stop
```

runtime image の中では `bin/a3` が Engine CLI として残る。これは内部互換名であり、利用者向けの正規入口は `a2o` と `a2o-agent` である。

現行の公開 launcher は setup、kanban lifecycle、agent install、foreground runtime execution、resident scheduler lifecycle を提供する。

## 実装位置

- Engine core: `lib/a3/`, `bin/a3`, `spec/`
- Host launcher / agent: `agent-go/`
- Docker runtime assets: `docker/`
- Kanban tooling: `tools/kanban/`
- Reference product packages: `reference-products/`
- 利用者向け docs: [docs/ja/user/](docs/ja/user/)
- 開発者向け docs: [docs/ja/dev/](docs/ja/dev/)

## Validation

reference product suite は次の 4 パターンを持つ。

- `reference-products/typescript-api-web/`
- `reference-products/go-api-cli/`
- `reference-products/python-service/`
- `reference-products/multi-repo-fixture/`

各 product は `project-package/` を持ち、`a2o project bootstrap --package <package>` で runtime instance を作成できる。suite の目的、package contract、検証境界は [docs/ja/dev/90-reference-product-suite.md](docs/ja/dev/90-reference-product-suite.md) を参照する。
