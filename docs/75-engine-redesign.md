# A3 Engine Redesign

## 目的

このメモは、A3 Engine の再設計方針を整理し、`A3Engine#2520` を具体的な設計タスクとして進めるための土台を残すものです。
current `a3-v2` を future `a3-engine` base として seed するため、`a3-engine/docs/REDESIGN.md` を取り込んだ current copy として扱う。

目標は次のとおりです。

- A3 Engine を他 project でも再利用しやすくする
- project 固有ロジックを engine から減らす
- `ai-cli` のような vendor-neutral な executor naming に寄せる
- 特定 OS やローカル実行環境への依存を減らす

これは設計メモであり、現行の運用契約そのものではありません。current runtime / operator surface の正本は `docs/60-container-distribution-and-project-runtime.md`、root `Taskfile.yml`、`scripts/a3/*.rb` を参照します。legacy automation docs は historical reference としてだけ扱います。

## 現状の痛み

- repo 名、検証方針、branch 振る舞いなどの project 固有事情が automation 側に埋め込まれている
- `Portal` の `ui-app` と `starters` のような非対称な phase policy が宣言ではなくハードコードで表現されている
- `implementation` / `inspection` / `merge` ごとの branch source-of-truth が十分に明示されておらず、inspection と merge の不整合を起こしうる
- executor 周りがまだ vendor 固有名を public interface に露出している
- `launchd`、PATH 正規化、vendor 由来 binary fallback など、実行環境依存が core 近傍に残っている

## 基本方針

### 1. A3 Engine は純粋な engine に閉じる

A3 Engine が持つ責務は orchestration に限定するべきです。

- kanban state transition
- lock / state file 管理
- issue workspace lifecycle
- inspection / merge handoff
- blocked recovery flow
- worker result schema
- executor / scheduler adapter

逆に、A3 Engine は次を直接持つべきではありません。

- project 固有の repo 一覧
- phase ごとの verification policy
- branch topology rule
- repo label と対象判定
- `Portal` 専用の例外処理
- project 固有 manifest の実体

### 2. project 定義は root repo から外部注入する

project 固有の定義は A3 Engine の内側ではなく、workspace composition を担う root repo 側に置く方がよいです。

想定する役割分担は次です。

```text
/root repo
  /a3-engine
  /ui-app repo
  /starters repo
```

- `a3-engine`
  - orchestration engine
  - executor / scheduler adapter
  - 共通 result schema と state machine
- `ui-app repo`
  - プロダクト本体
- `starters repo`
  - 共通コンポーネント
- `root repo`
  - workspace composition
  - project manifest の正本
  - launcher / bootstrap
  - 横断 docs

この構成では、`root repo` が project 固有 manifest を保持し、launcher がその manifest を `a3-engine` に渡して起動します。

### 3. project profile は宣言的 manifest を正本にする

v1 では project profile を Python module として `a3-engine` に置くのではなく、root repo 側の宣言的 manifest を正本にする方がよいです。

主な理由は次です。

- project 固有事情を `a3-engine` に逆流させないため
- 他 project へ横展開するときに review しやすくするため
- 差分を設定変更として追いやすくするため
- engine の contract test と project 定義の validation を分離しやすくするため

ここでいう manifest は task 名の列挙ではなく、project の automation contract を表現する設定です。

### 4. hook ではなく engine capability で表現する

project 固有の特殊処理を code hook として差し込む方向は、原則として避けるべきです。

`Portal#2514` で見えてきた論点は、hook が欲しいのではなく、project profile が「必要な前処理・検証・前提条件」を十分に表現できていないことでした。

したがって、再設計では次の方針を取ります。

- project 側は宣言に徹する
- manifest で表現できない要件が出たら、project 側 hook を足すのではなく engine に capability を追加する
- capability は他 project でも再利用可能な粒度で設計する

## project manifest が持つべき内容

manifest は最低でも次を表現できる必要があります。

- project metadata
- repo inventory
- repo ごとの canonical branch
- parent-child flow rule
- phase contract
- verification intent
- cross-repo prerequisite
- branch contract
- preflight guard

### project metadata

- kanban project 名
- trigger label
- parent trigger label
- task 分類ルール

### repo inventory

- 対象 repo 一覧
- root repo から見た path
- repo ごとの役割

### phase contract

phase ごとに次を定義できる必要があります。

- 対象 repo
- 必須 verification
- 任意 verification
- parent flow 時の扱い
- blocked 時の扱い

### verification intent

manifest には `test:all` のような task 名ではなく、まず「何を確認するか」を表現させるべきです。

例:

- formatting
- static analysis
- unit / integration test
- null-safety gate
- generated artifact / knowledge drift check
- cross-repo install / bootstrap prerequisite

各 repo はこれを repo-local command へ解決します。

これにより、`Portal` のように `ui-app` と `starters` で非対称な policy を持っていても、project 側の宣言として表現できます。

### repo-local command mapping

実際の command 文字列は engine に埋め込まず、project 側の manifest から参照される mapping として扱う方がよいです。

責務は次です。

- verification intent を repo-native command set に解決する
- repo ごとの gate 粒度差を吸収する
- `ui-app` と `starters` の非対称な運用を project 側で閉じる

## branch contract

各 phase は、どの branch / ref を正本として扱うかを明示的に宣言する必要があります。

最低でも次を分けて扱います。

- source-of-truth workspace
- source branch / ref
- runtime / result workspace
- live repo state

これらは同じ「branch」に見えても責務が違います。

- `implementation` / `review` / `inspection` は、どの workspace clone と branch を検査対象の正本にするか
- runtime / result workspace は、isolated な実行・result 保持の場であり、検査対象の正本そのものではない
- `merge` は、どの source branch を apply するかに加えて、live repo 側がどの canonical branch / state にあるべきかも別契約として持つ
- parent flow では `merge target` と live repo current branch の canonical state が一致しないことがあるため、両者を分けて扱う必要がある

この観点は `Portal#2517` と `Portal#2519` で具体化されました。

- `Portal#2517`
  - inspection runtime workspace と source-of-truth issue workspace を混同すると、inspection と merge の検査対象がずれる
- `Portal#2519`
  - merge target branch だけを見ても不十分で、live repo current branch の canonical state も guard しないと戻し漏れを検知できない

したがって branch contract は最低でも次を持てる必要があります。

- phase が参照する source-of-truth workspace
- phase が使う source branch / ref
- phase 実行用 runtime workspace
- live repo 側で要求される canonical branch / state
- parent flow 時の source branch と merge target の分離

core は宣言された contract を materialize するだけに留め、暗黙の project 挙動から推測してはいけません。

## preflight guard

phase の本処理に入る前に、deterministic な preflight guard を持てるようにするべきです。

対象例:

- live repo が canonical branch にいるか
- live repo が dirty でないか
- prerequisite artifact / commit / branch が揃っているか
- inspection / merge が正しい workspace / branch を参照しているか

重要なのは、これを単なる実装都合ではなく contract として扱うことです。

- preflight failure は process crash ではなく `blocked` に正規化されるべき
- blocked comment / failing_command から expected / actual が読めるべき
- guard は phase 開始前だけでなく、必要なら phase 実行中にも再検証できるべき
- manifest は repo ごと / phase ごとに必要な preflight guard を宣言できるべき

これも `Portal#2519` で明確になった点です。

- 入口で早期 blocked
- merge 本体でも再検証

という二段ガードが必要だったため、再設計でも「phase command」だけでなく「phase preflight」を first-class に扱う必要があります。

## executor / scheduler の分離

### executor adapter

orchestrator は `codex exec` に直接依存するのではなく、汎用的な worker-executor contract に依存するべきです。

executor adapter が持つ責務は次です。

- prompt transport
- process launch syntax
- result collection
- runtime 固有の環境セットアップ

`Codex` は対応 adapter の一つとして残してよいですが、core contract を定義する存在にはしない方がよいです。

これにより、将来的には次のような差し替えが可能になります。

- Codex
- GitHub Copilot CLI
- その他の one-shot LLM runner
- 必要なら手動 / 半手動の execution mode

### scheduler / runtime adapter

scheduler 層は `launchd` 前提で設計しない方がよいです。

scheduler contract としては、少なくとも次を扱えるべきです。

- cron
- launchd
- systemd timer
- CI / manual one-shot execution

環境解決も runtime 非依存に寄せるべきです。

特に次は見直し対象です。

- core が Codex vendor fallback に頼って基本 tool を探さないこと
- 必須 binary は明示チェックすること
- runtime 固有の PATH 救済は orchestration core ではなく runtime adapter 側へ寄せること

### manifest と launcher config の境界

`2521` に入る前に、project manifest と launcher / scheduler config の境界を明確にしておく必要があります。

project manifest が持つべきもの:

- kanban project 名
- trigger / blocked label
- repo inventory
- repo selection
- phase contract
- branch contract
- preflight guard

launcher / scheduler config が持つべきもの:

- executor runtime 種別
- executor launcher binary / argv
- scheduler backend 種別
- scheduler interval / restart policy
- shell binary / login / interactive policy
- inherit_env / env_files / env_overrides
- env file / secret source
- PATH 正規化方針
- host 固有の install path や process supervisor 前提

この分離により、A3 Engine 自体は project contract を理解しつつ、machine-local な運用設定は root launcher 側で差し替えられる。

### `2521` 着手前に決めておくべき adapter interface

`2533` で runner entrypoint はできたが、`2521` に入るには次の interface を先に固定する必要がある。

- executor adapter interface
  - one-shot 実行コマンドの組み立て
  - prompt/result transport
  - runtime 固有 env 構築
- scheduler adapter interface
  - one-shot job の起動方法
  - lock / observability / restart の外側責務
  - scheduler status / restart / stop の control surface
- runtime environment interface
  - normalized PATH の解決
  - 必須 binary チェック
  - runtime ごとの home/config sandbox

`2521` では、この interface 定義を先に code と文書へ落とし、その後に launchd 依存の実装を adapter 側へ移す。

## 推奨する進め方

### Step 1. engine と外部 interface の contract を固める

最初に architecture boundary を固定します。

- engine の責務
- root repo launcher の責務
- project manifest schema
- executor adapter の責務
- scheduler / runtime adapter の責務
- branch contract model

先に大規模な file move を始めるのではなく、まず interface を固めるべきです。

### Step 2. root repo 側に `Portal` manifest を作る

現行 `Portal` の挙動を、見た目の flow を変えずに external manifest として表現します。

この manifest が持つべき内容は次です。

- `ui-app` と `starters` の repo 定義
- repo × phase ごとの verification policy
- parent flow rule
- phase ごとの branch contract
- phase ごとの preflight guard
- blocked recovery policy
  - refresh failure は task-specific terminal failure として扱い、lane unclogging のための手動復旧を正規経路に含めない

最初の成功条件は「十分に汎用的か」ではなく、「`Portal` が external manifest 経由で動き、`a3-engine` から `Portal` 専用分岐が消えるか」です。

### Step 3. branch/ref 問題を contract 化と同時に直す

`Portal#2517` で見つかった inspection / merge の branch mismatch は、manifest 化の後回しにせず、同じ設計作業の中で解消するべきです。

inspection と merge が常に意図した ref を使うよう、branch contract を宣言的に表現できる状態まで持っていく必要があります。

### Step 4. executor adapter を切り出す

manifest 境界が安定したら、`Codex` 固有の launch behavior を executor adapter に移します。

この段階では次を維持します。

- Codex 実行は壊さない
- 現行の worker result JSON は維持する
- kanban flow は変えない

目的は Codex を即時置き換えることではなく、runtime 固有ロジックを automation engine から追い出すことです。

### Step 5. scheduler / runtime adapter を切り出す

executor 分離の次に、scheduler / runtime 依存を外出しします。

- 先に executor / scheduler / runtime-env の adapter interface を固定する
- 次に launcher config と manifest の責務境界を固定する
- launchd 固有の起動経路
- PATH 正規化方針
- machine-local な救済ロジック

この文脈で `Portal#2494` を扱うのが自然です。

### Step 6. 2 本目の軽量 project で抽象化を検証する

`Portal` がきれいに manifest 化できてから、次の project で abstraction の妥当性を確かめます。

`Portal` だけを見て早く抽象化しすぎると、実際には `Portal` 固有事情を隠しただけの設計になりやすいです。

## 責務分担

### automation engine

持つもの:

- flow state machine
- reconcile logic
- workspace lifecycle
- result handling
- blocked / unblocked orchestration
- executor / scheduler adapter interface

持たないもの:

- project 固有 manifest
- project 固有 repo inventory
- project 固有 phase policy

### root repo launcher / manifest

持つもの:

- project manifest の正本
- workspace composition
- launcher / bootstrap
- repo-local command mapping
- executor / scheduler config source
- env file / secret handoff

### repo-local task contract

持つもの:

- 実際の build / test / lint command
- tool 固有 command の組み立て
- repo-native gate 定義

### executor adapter

持つもの:

- runtime 固有 command line
- auth / config handoff
- prompt / result transport

### scheduler / runtime adapter

持つもの:

- 起動方式
- 環境準備
- host 固有の実行詳細

## ticket 対応

- `Portal#2493`
  - engine と external manifest 注入モデルの親設計タスク
- `Portal#2517`
  - branch/ref source-of-truth と inspection / merge 整合
- `Portal#2519`
  - live repo canonical branch guard と preflight contract
- `Portal#2494`
  - scheduler packaging と runtime-environment 分離

必要なら、executor 分離は `2494` に詰め込まず、別 follow-up task として独立させてもよいです。

## 非目標

- Kanban / Taskfile を control surface から外すこと
- project-specific code hook を先に導入すること
- 全 automation script を一度に書き直すこと
- `Portal` が整理できる前に全 project 対応を目指すこと

## 実務上の結論

進め方としては次の順が妥当です。

1. engine と external interface を設計する
2. root repo に `Portal` manifest を置く
3. その過程で branch/ref semantics を直す
4. executor runtime 依存を adapter 化する
5. scheduler / host-environment 依存を adapter 化する
6. 2 本目の project で抽象化を検証する

この順なら、現実の `Portal` の課題に根ざしたまま、再利用可能な automation platform へ段階的に移行できます。
