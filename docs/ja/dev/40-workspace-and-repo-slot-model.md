# A2O Workspace And Repo Slot Model

この文書は workspace topology、repo slot、source synchronization、freshness、retention、merge behavior を定義する。

## Goals

- Product repository layout を Engine core へ持ち込まない。
- Runtime state と job payload では stable repo slot alias を使う。
- Phase execution の前に source refs を明示する。
- Agent workspace は disposable に保つ。
- Blocked / completed work を調査できる evidence を保持する。

## Repo Slots

Repo slot は repository に対する stable project package alias である。

例:

```yaml
repos:
  app:
    path: ..
    role: product
    label: repo:app
```

Runtime code は local filesystem path ではなく `app` を stable identifier として使う。

## Source Aliases

Host launcher は package repo slots を agent source aliases へ展開する。Agent は project package を parse せず、その alias を使って workspace を materialize する。

## Workspace Kinds

### Ticket Workspace

Implementation 用に使う。Agent は task 用の editable source を materialize し、結果を task work branch へ publish する。

### Runtime Workspace

Review、verification、merge 用に使う。明示的な source descriptor から作成し、偶然の local checkout state に依存しない。

## Branch Namespace

User-visible branch refs は A2O 名を使う。

```text
refs/heads/a2o/<instance>/work/<task>
refs/heads/a2o/<instance>/parent/<task>
```

Namespace には runtime instance を含める。これにより、isolated boards が小さい task number を再利用しても衝突しない。

A2O は user-visible branch refs を `refs/heads/a2o/...` 配下へ書く。`refs/heads/a3/...` refs を見つけた場合は public branch naming ではなく internal compatibility data として扱う。

## Freshness

Workspace materialization は、workspace が requested source descriptor と一致することを確認しなければならない。一致しない場合、A2O は stale state を黙って再利用せず、recreate または refresh する。

Dirty source repository は fail fast し、diagnostics に repo と file list を含める。

## Cleanup

Generated runtime output は `.work/a2o/` 配下に置く。

Materialized repo slot の agent metadata は product repo slot checkout の外にある A2O-managed metadata path に置く。Product repo slot に A2O-owned `.a3/slot.json` や `.a3/materialized.json` を置いてはならない。

Cleanup policy は、disposable workspace を再生成可能にしつつ、blocked diagnosis と release validation に必要な evidence を保持する。

## Merge

Merge は project package と runtime state にある明示的な source / target refs を使う。

Internal merge targets:

- child to parent integration ref
- parent to live target
- single task to live target

Merge policy は project package の一部である。Package が別 policy を明示しない限り、default policy は fast-forward only である。
