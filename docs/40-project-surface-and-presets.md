# A3 Project Surface and Presets

対象読者: A3 設計者 / PJ manifest 設計者 / 実装者
文書種別: 設計メモ

この文書は、A3 における PJ 固有知識の表現面を最小集合に絞り、
巨大な product surface にならないようにするためのもの。

## 1. 目的

- PJ 固有知識の注入面を最小集合に絞る
- V1 の複雑性を別レイヤへ横流ししない
- manifest を「何でも書ける設定ファイル」ではなく、preset をベースに差分だけを持つ surface にする

## 2. 原則

### 2.1 最小 surface

PJ が自由に差し替える surface は次を基本とする。

- implementation skill
- review skill
- verification commands
- remediation commands
- workspace hook

これ以上の注入点は、既存 surface や variant/preset で吸収できない場合に限って検討する。

### 2.2 core config と PJ surface を分ける

次は core execution config であり、PJ の自由拡張 surface とは分ける。

- task kind
- branch topology
- merge target
- merge policy
- workspace topology
- rerun semantics

PJ はこれらの意味を上書きしない。

`merge target` と `merge policy` は次のように扱う。

- core config
  - 許可される merge topology と merge policy の型を定義する
  - 例: `merge_to_live`, `merge_to_parent`, `ff_only`, `no_ff`
- preset
  - task kind / topology に応じた既定値を選ぶ
- project override
  - core config が許可した候補の中から選択だけできる
  - 新しい merge semantics を定義してはならない

### 2.3 variant で吸収する

`parent review` や `repo kind` の差を、新しい surface 増設で解かない。

差分は次の入力で variant として解決する。

- task kind
- repo scope
- phase

## 3. Minimal Injection Surface

### 3.1 implementation skill

implementation worker に渡す skill。

役割:

- 実装時の行動規範
- 変更のまとめ方
- commit 前に見るべき観点

### 3.2 review skill

review worker に渡す skill。

役割:

- review 観点
- findings の出し方
- current canonical flow では parent review の観点差を variant で吸収する

single / child では `review_skill` を phase surface としては使わず、implementation evidence の self-review / findings fix に吸収する。

### 3.3 verification commands

runner-owned verification で実行する deterministic gate 群。

役割:

- build
- test
- static checks
- generated artifact checks

### 3.4 remediation commands

verification failure に対する自動補正・再実行前処理。

役割:

- formatter 適用
- generated artifact 再生成
- lightweight recovery

ただし、意味判断を伴う修正は remediation に入れない。

### 3.5 workspace hook

workspace 作成直後または repo slot 準備後の補助処理。

役割:

- bootstrap
- local dependency setup
- knowledge/build cache の初期化

workspace hook は repo の存在そのものを変えるためには使わない。

## 4. Variant Resolution

variant 解決は、surface の種類ごとに無制限に分岐させない。

初期前提の key は次とする。

- `task_kind`
- `repo_scope`
- `phase`

例:

- `review skill`
  - child + repo-alpha
  - child + repo-beta
  - parent + both

同じ意味の分岐を skill 側と command 側に二重で持たない。

### 4.1 初期解決順序

variant は次の順で解決する。

1. `task_kind`
2. `repo_scope`
3. `phase`

より後段の key は、前段で選ばれた variant tree の内部でだけ評価する。
これにより、同値な条件分岐が preset と manifest の両方へ重複するのを避ける。

## 5. Preset Strategy

PJ はゼロから manifest を書くのではなく、preset を土台に差分だけを定義する。

### 5.1 初期 preset 候補

- single issue preset
- parent-child preset
- Java child preset
- frontend child preset

### 5.2 preset layering

例:

1. base preset
2. topology preset
3. repo kind preset
4. project override

この順で override されることを前提とする。

override 衝突は「後勝ち」で黙殺しない。
同じ key に対して互換しない値が重なった場合は、preset loader が configuration error として fail-fast する。

### 5.3 boilerplate

最初から提供するもの:

- sample manifest
- sample hook
- sample skill
- example preset chain

## 6. Manifest の責務

manifest は「domain rule を書く場所」ではない。

manifest が持つのは次までに留める。

- どの preset を使うか
- どの skill/command/hook を選ぶか
- どの variant が適用されるか

manifest が持たないもの:

- phase transition rule
- rerun rule
- blocked classification rule
- workspace existence rule

## 7. Non-Goals

この文書の文脈では、次を非採用とする。

- formatter/test framework 名を engine 側へ増やすこと
- parent review のためだけに専用 surface を増やすこと
- PJ ごとに branch topology や rerun semantics を自由に上書きさせること
- 何でも書ける巨大 manifest DSL を作ること

## 8. 後続へ渡す論点

- `3028`
  - preset loader / variant resolver の初期実装
- 実装時 TODO
  - variant 解決順序をコード上でどう表現するか
  - preset override の衝突をどう検出するか

## 9. この文書の完了条件

- PJ 注入面が最小集合として定義されている
- core config と PJ surface の境界が定義されている
- variant で差分を吸収する方針が定義されている
- preset / boilerplate の前提が定義されている
- manifest が domain rule を持たないことが明記されている
