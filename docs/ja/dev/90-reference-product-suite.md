# A2O Reference Product Suite（reference product suite の構成）

対象読者: A2O runtime 実装者 / validation 設計者 / operator
文書種別: validation 方針

この文書は、A2O core validation で使う owned sample products を定義する。

## 目的

A2O は 1 つの stack に依存せず、一般的な product shapes で動作する必要がある。Reference suite は、runtime、agent、kanban、verification、merge、parent-child flows を exercise する小さく review しやすい projects を A2O に提供する。

## Suite Shape（suite の構成）

| Product | Path | Purpose |
|---|---|---|
| TypeScript API/Web | `reference-products/typescript-api-web/` | 1 repository 内の API and browser UI |
| Go API/CLI | `reference-products/go-api-cli/` | 1 Go module 内の server and CLI |
| Python Service | `reference-products/python-service/` | lightweight service and Python verification |
| Multi-repo Fixture | `reference-products/multi-repo-fixture/` | parent-child and cross-repo validation |

各 product は package を `project-package/` に置く。

## Package Contract（package contract の内容）

各 package は次を含む。

- `README.md`
- `project.yaml`
- `commands/`
- `skills/`
- `task-templates/`

Package は deterministic な test または build command、agent prerequisites、editable source boundaries、kanban board に置ける task template を少なくとも 1 つ定義する。

`project.yaml` は単一の author-facing package config file である。package identity、kanban selection、repo slots、agent prerequisites、runtime surface commands、merge defaults を持つ。

## Validation Boundary（validation boundary の考え方）

Core validation は reference suite から始める。runtime、workspace、worker gateway、verification、merge、package preset の変更が少なくとも 1 つの reference product で検証できない場合、external product evidence に頼る前に reference task template を追加または改善する ticket を作成する。

Suite 改善中に external behavior changes が見つかった場合は、implementation 前に owner と協議する。

## Release Validation Scope（release validation の範囲）

Suite は次の release validation target である。

- single-repo implementation / verification / merge
- multi-repo child implementation and verification
- child-to-parent merge
- parent review and verification
- parent live merge
- runtime watch summary and task diagnostics
- evidence persistence

Validation runs では、model variability を切り離すため deterministic workers を使ってよい。ただし exercise する surfaces は実物のままにする。対象は kanban pickup and transitions、branch namespace creation、workspace materialization、worker gateway transport、agent-side publication、verification commands、merge、evidence persistence である。
