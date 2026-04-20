# Runtime Extension Boundary（runtime extension の境界）

A2O Engine core は project-neutral に保つ。Project-specific behavior は project packages、command profiles、hook scripts、task templates、agent-side toolchains を通じて注入する。

## Runtime flow 上の位置づけ

この文書は、runtime flow のどこまでを A2O core が持ち、どこからを project package / command / skill に委譲するかを定義する。新しい要件が出たとき、core behavior と project-specific extension のどちらに置くべきかを判断するために読む。

## Core が知ってよいもの

- task lifecycle phases
- kanban provider interface
- repo slot model
- workspace materialization
- worker gateway protocol
- verification result semantics
- merge publication semantics
- evidence storage

## Project Package が所有するもの

- board name and project-owned bootstrap labels
- project-owned task labels
- repo slot aliases and source paths
- build/test/format commands
- `a2o-agent` 用 environment prerequisites
- validation 用 task templates
- project-specific bootstrap、remediation、verification hooks（project 固有 hooks）

## Injection Rules（注入 rules）

1. product、repository、domain concept、build tool、verification command を指す値は project package に置く。
2. すべての A2O project に必要な behavior は Engine domain logic として表現し、core tests で cover する。
3. 1 つの project だけが必要とする behavior は package hook または command profile を優先する。
4. 2 つ以上の reference products が同じ behavior を必要とする場合は、documented preset への昇格を検討する。
5. config 不在時に project package を黙って再生成する fallback defaults を追加しない。

## Current Package Layout（現在の package layout）

Reference packages は次の形を使う。

```text
project-package/
  README.md
  project.yaml
  commands/
  skills/
  task-templates/
```

`project.yaml` は唯一の author-facing package config である。package metadata、kanban bootstrap and selection、repo slots、agent prerequisites、runtime surface commands、merge defaults を持つ。A2O-owned lanes と internal coordination labels は provider/runtime defaults であり、package responsibilities ではない。`commands/` は declarative commands では不足する場合の project-owned scripts を置く。`task-templates/` は validation に使う kanban task templates を置く。

## Review Checklist（review checklist の確認項目）

- Package は `a2o project bootstrap` で bootstrap できる。`./a2o-project` または `./project-package` にない場合は `--package DIR` を使う。
- Repo aliases は stable であり、local machine paths を encode しない。
- Required binaries は `agent.required_bins` に列挙する。
- Build and verification commands は agent-materialized workspace から実行できる。
- Scenario tasks は deterministic validation に使える小ささに保つ。
- Package が必要とする外部 A2O behavior change は、implementation 前に別 ticket として track する。
