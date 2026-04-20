# A2O Engineering Rulebook

この文書は A2O の日常的な engineering rule を定義する。Design document は何を作るかを定義し、この文書はどう作るかを定義する。

## Core Rules

- Domain object は immutable を優先する。
- Red -> Green -> Refactor の短い loop を使う。
- Behavior を変える前に failing test を追加する。
- 重複した knowledge や不明瞭な責務が見えたら refactor する。
- 変更を小さく見せるために必要な修正を避けない。
- Product-specific behavior を Engine core へ入れない。

## Immutability

Domain object は原則 immutable である。State change は existing object を mutate するのではなく、新しい object を返すべきである。Mutable state を許すのは infrastructure や adapter concern の場合だけであり、その boundary は明示する。

Task、run、evidence のような core concept に ad hoc setter や hidden mutation を増やしてはならない。

## TDD

最小で有効な loop を使う。

1. Code 上の design pressure を固定する failing test を書く。
2. その test を通す最小実装を追加する。
3. Behavior を変えずに refactor する。

Test を省略してよいのは、完全に機械的な変更または documentation-only change の場合だけである。Shared behavior、public CLI behavior、runtime orchestration、workspace materialization、verification、merge、diagnostics には test が必要である。

## Refactoring

Refactoring は postponed cleanup phase ではなく、通常の実装中に行う。同じ knowledge が 2 箇所に現れたら、ownership boundary を早めに確認する。

Future variation だけを理由に abstraction を追加しない。現在の complexity を減らす、意味のある duplication を減らす、または既存 local pattern に合う場合に追加する。

## Review Standard

Reviewer は次を優先して確認する。

- behavioral regressions
- incomplete ticket coverage
- missing tests
- unclear public/internal surface boundaries
- product-specific assumptions in core code
- user-facing diagnostics that do not explain the next action

Documentation と tests は release surface の一部である。

## Boundaries

Validation fixture、temporary note、特定 product の operational workaround を standard Engine concept にしてはならない。External behavior の変更が必要な場合は、実装前に product impact を協議する。
