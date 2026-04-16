# A2O Reference Product Suite

対象読者: A2O runtime 実装者 / validation 設計者 / operator
文書種別: validation 方針

この文書は、A2O core validation で使う reference product suite の方針を定義する。
Portal は実プロダクトであり、A2O 開発の実験台として日常的に使わない。

## 目的

A2O は OSS として、特定の顧客プロダクトや Java/Spring Boot/Maven 構成に依存しない runtime / agent / kanban / parent-child flow を検証できる必要がある。
そのため、A2O 専用の小さな reference product を複数用意し、core validation の正本にする。

## Validation Boundary

A2O core validation は reference product suite を使う。
Portal 固有の validation は、A2O core validation ではなく実プロダクト integration validation として扱う。

この境界により、A2O の通常開発では次を避ける。

- Portal の business domain や repo-local command を A2O core の前提にすること
- Portal 固有の Java / Maven / Node runtime を A2O runtime image へ戻すこと
- Portal の実 source repo を軽量 regression の実験台にすること
- Portal 固有の失敗を A2O 汎用 contract と誤認すること

Portal validation を実行してよいのは、release candidate、実プロダクト integration 確認、または Portal package 自体の変更確認に限る。
その場合も A2O core の完成条件とは別に記録する。

## Suite Shape

Reference product suite は次の 4 パターンで構成する。

| Ticket | Pattern | Purpose |
|---|---|---|
| `A2O#255` | TypeScript / Node.js API + Web UI | Web UI と API を持つ一般的な full-stack product を検証する |
| `A2O#256` | Go API + CLI | single binary / CLI / API server の組み合わせを検証する |
| `A2O#257` | Python service | lightweight service と Python toolchain を検証する |
| `A2O#258` | Multi-repo cross-product fixture | parent-child flow、repo slot、cross-repo merge / verification を検証する |

各 reference product は小さく保つが、実プロダクト風の domain、test、build、agent が編集できる余地を持つ。
単なる toy fixture ではなく、A2O の runtime contract が壊れたときに失敗として観測できる構造を持たせる。

## Acceptance Requirements

各 reference product は少なくとも次を持つ。

- README または project manifest に、domain、主要 command、validation intent を明記する
- deterministic な test / build command
- agent が編集してよい source file と、編集してはいけない generated / cache file の境界
- A2O runtime が task を作成し、実装、検証、必要なら merge まで進められる最小 kanban scenario
- A2O の外部仕様変更が必要になった場合に、実装前に owner と協議する明記

## Migration Rule

今後の A2O runtime / agent validation は、まず reference product suite に追加する。
Portal でしか再現しない事象は、reference product へ切り出せる最小ケースを先に作る。
切り出せない場合だけ Portal integration validation として実行し、A2O core の汎用要件とは分けて扱う。

Portal 由来の historical evidence は削除しない。
ただし、新しい daily / focused / release-facing core validation の入口には Portal を正本として追加しない。
