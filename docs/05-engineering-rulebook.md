# A3-v2 Engineering Rulebook

対象読者: A3-v2 実装者 / reviewer
文書種別: 実装規律

この文書は、A3-v2 実装時に常に守るべき開発ルールを固定する。
設計書が「何を作るか」を定義するのに対し、この文書は「どう作るか」を定義する。

## 1. 目的

- 実装品質のばらつきを減らす
- V1 で繰り返した場当たり修正を防ぐ
- TDD と DDD の両立を、日々の実装判断に落とす
- 「影響範囲を増やしたくない」という理由で必要な修正を避けることを禁止する

## 2. 基本原則

### 2.1 可能な限り immutable に実装する

- domain object は原則 immutable とする
- 状態更新は既存 object の破壊ではなく、新しい object を返す
- mutable state を持つ場合は、infrastructure や adapter の都合であることを明示する
- `task` / `run` / `evidence` などの core model に、場当たりな setter や hidden mutation を入れない

### 2.2 t-wada の TDD を守る

- 実装は `Red -> Green -> Refactor` の短いループで進める
- 先に設計をコードへ焼き付ける最小 failing test を書く
- 通すための最小実装を入れる
- 振る舞いを変えないリファクタリングを適切なタイミングで挟む

TDD を省略して一気に書くことを常態化させない。

### 2.3 リファクタリングは必要なタイミングで行う

- リファクタリングは「最後にまとめて」ではなく、ループの途中で小さく入れる
- 同じ知識が 2 か所へ現れたら、早めに責務の所在を見直す
- 不変条件を壊しやすい実装、説明しにくい実装、責務が曖昧な class は放置しない

ただし、先走った抽象化で class を増やしすぎない。
必要性が test とコードから見えた時にだけ進める。

### 2.4 必要な修正から逃げない

次のような理由で必要な修正を避けることを禁止する。

- 影響範囲を広げたくない
- 既存 fixture を崩したくない
- いったん optional にして逃がしたい
- 一時的に互換性を残したい
- fallback で旧経路を残したい
- 複数の result shape / command path / session path を暫定併存させたい

影響範囲が広いことは、修正を避ける理由ではなく、分割して安全に直す理由である。

## 3. 判断ルール

### 3.1 最小実装の意味

`最小実装` は、必要な修正を薄めることではない。

意味するのは次だけである。

- 必要な問題を、最短で再現できる test に絞る
- その test を通すための最小コードを書く
- 余計な派生機能を同時に作らない

意味しないもの:

- 必須の domain field を optional に逃がす
- 本来必要な validation を抜く
- 設計で決めた責務境界を暫定的に崩す

### 3.2 互換性の扱い

A3-v2 は新規実装であり、V1 互換を最優先しない。

- 互換性維持は、設計に沿う場合だけ採る
- 設計に反する互換レイヤは作らない
- 「今の test fixture が楽」という理由で、誤った contract を残さない
- release 前は、後方互換を理由に optional field、fallback 分岐、二重経路、`respond_to?` ベースの吸収層を残さない

### 3.3 影響範囲の扱い

影響範囲は小さく保つべきだが、修正の本質を削ってはならない。

正しい進め方:

- 修正対象の本質を特定する
- failing test を 1 つずつ足す
- 必要な domain/application/adapter の修正を入れる
- その単位ごとに green に戻す

誤った進め方:

- 本質修正を避け、暫定 flag や optional field で逃がす
- domain に置くべき知識を application/infra の分岐へ押し込む
- formatter / adapter / CLI で複数 shape を暫定吸収し、正規 contract への統一を先送りする

## 4. DDD との関係

このルールブックは、DDD を実装上で守るための補助線でもある。

- domain knowledge は domain に置く
- orchestration は application に置く
- persistence / process / file I/O は infra に置く
- format 変換は adapter に置く

「どこに置くべきか分からない知識」は、そのまま実装せず設計へ戻す。

## 4.1 案件固有情報を A3 本体へ持ち込まない

A3 は product / engine であり、個別案件の名称・前提・語彙を本体の公開 contract に含めない。

- 案件名を command 名、value object、field 名、summary 文言に入れない
- 案件固有の runtime 手順は、A3 本体ではなく injected config / manifest / preset / runtime package で表現する
- 案件固有の判断は A3 の domain rule に埋め込まず、project context として外から与える
- 案件固有の build/test/remediation command、hook path、repo topology 名、repo path 規約を、A3 同梱 preset や product docs の正本へ埋め込まない

許されるのは次だけである。

- 実行時に manifest / preset / runtime package から案件情報を注入する
- operator 向け表示で injected な案件情報を透過的に出す

禁止されるもの:

- 特定案件名を A3 本体 command や domain contract に入れる
- 特定案件向け canary / migration / workspace rule を A3 の標準機能名として固定する
- 直近導入案件の都合を、そのまま A3 の ubiquitous language に昇格させる
- 特定案件や特定 project の toolchain knowledge を、A3 の base preset / bundled preset / CLI の既定分岐として固定する

## 5. Review 観点

reviewer は次を必ず確認する。

- mutation が不要に入り込んでいないか
- test 先行になっているか
- refactor を後回しにして知識が重複していないか
- `影響範囲を減らす` を理由に必要な修正が削られていないか
- 設計書で決めた contract を optional や fallback で濁していないか
- release 前なのに、後方互換や逃げのための二重経路・暫定吸収層・multi-shape support を残していないか
- 案件固有語彙や案件前提を、A3 本体の command / domain / contract に持ち込んでいないか
- 案件固有知識を、A3 本体の bundled preset / docs / default command / fixed repo topology に持ち込んでいないか

## 6. この文書の位置づけ

- A3-v2 実装時の常時ルールとする
- README と design map から辿れるようにする
- 実装中に迷ったら、この文書を優先して判断する

## 7. 完了条件

- immutable / TDD / refactor / 必要修正を避けない、の 4 原則が明文化されている
- `最小実装` と `互換性維持` の誤用を防ぐ文面になっている
- reviewer が review 観点として直接使える
