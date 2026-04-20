# A2O Engine

A2O の正式名称は Agentic AI Orchestrator である。A2O は kanban 上の task を読み取り、作業用 workspace、agent 実行、検証、merge、evidence 記録までを管理する automation engine である。

![A2O システム概観](docs/assets/a2o-system-overview.ja.svg)

この図は、利用者が kanban task と project package を用意し、A2O Engine が task を選び、`a2o-agent` が生成AIと product toolchain を使って Git repository に変更を反映し、結果を kanban と evidence に残す流れを表す。

## A2O が解決すること

A2O は、AI に実装を任せるために必要な周辺作業を runtime としてまとめる。

| 観点 | 内容 |
|---|---|
| 利用者が用意するもの | Git repository、project package、AI 用 skill、kanban task |
| A2O が進めること | task pickup、phase job 作成、agent execution、verification、merge |
| 結果が残る場所 | Git branch / merge result、kanban status / comment、evidence、agent artifact |
| 利用者が確認するもの | board の状態、`watch-summary`、`describe-task`、Git の変更 |

## 通常の流れ

```text
kanban task
  -> A2O Engine が runnable task を選ぶ
  -> project.yaml / skill から phase job を作る
  -> a2o-agent が生成AIと product toolchain を使って実行する
  -> Git repository に変更が残る
  -> kanban comment / status / evidence に結果が残る
```

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
7. [docs/ja/dev/55-project-script-contract.md](docs/ja/dev/55-project-script-contract.md)
8. [docs/ja/dev/60-evidence-and-rerun-diagnosis.md](docs/ja/dev/60-evidence-and-rerun-diagnosis.md)
9. [docs/ja/dev/70-agent-worker-gateway-design.md](docs/ja/dev/70-agent-worker-gateway-design.md)
10. [docs/ja/dev/80-runtime-extension-boundary.md](docs/ja/dev/80-runtime-extension-boundary.md)
11. [docs/ja/dev/90-reference-product-suite.md](docs/ja/dev/90-reference-product-suite.md)
12. [docs/ja/dev/95-kanban-adapter-boundary.md](docs/ja/dev/95-kanban-adapter-boundary.md)

最小導入手順は [docs/ja/user/10-quickstart.md](docs/ja/user/10-quickstart.md) にまとめている。公開 command と runtime image の範囲は [docs/ja/user/80-current-release-surface.md](docs/ja/user/80-current-release-surface.md) を参照する。
