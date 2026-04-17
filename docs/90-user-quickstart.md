# A2O User Manual

対象読者: A2O 利用者 / project maintainer
文書種別: 利用手順

A2O は kanban task を起点に、workspace 作成、agent 実行、検証、merge、evidence 記録を進める automation engine である。利用者は project package を用意し、A2O の公開コマンドで runtime を起動する。

既存 package を `manifest.yml` と `project.yaml` の 2 ファイル構成から移行する場合は、先に [91-project-yaml-migration-guide.md](91-project-yaml-migration-guide.md) を読む。

## A2O が持つもの

- bundled kanban service lifecycle
- Engine runtime image
- host launcher `a2o`
- agent binary `a2o-agent`
- workspace and branch namespace management
- worker gateway, verification, merge, evidence storage

## 利用者が用意するもの

利用者が用意するのは project package である。project package は product repo の近くに置き、A2O が読む設定と scenario をまとめる。

```text
project-package/
  README.md
  project.yaml
  kanban/bootstrap.json
  commands/
  skills/
  scenarios/
```

`project.yaml` は project package の唯一の公開 config である。

```yaml
schema_version: 1
package:
  name: a2o-reference-typescript-api-web
kanban:
  provider: soloboard
  project: A2OReferenceTypeScript
  bootstrap: kanban/bootstrap.json
  selection:
    status: To do
repos:
  app:
    path: ..
    role: product
agent:
  workspace_root: .work/a2o-agent/workspaces
  required_bins:
    - git
    - node
    - npm
runtime:
  live_ref: refs/heads/main
  max_steps: 20
  agent_attempts: 200
  presets:
    - base
  surface:
    implementation_skill: skills/implementation/base.md
    review_skill:
      default: skills/review/default.md
    verification_commands:
      - app/project-package/commands/verify.sh
    remediation_commands:
      - app/project-package/commands/format.sh
    workspace_hook: app/project-package/commands/bootstrap.sh
  merge:
    target: merge_to_live
    policy: ff_only
    target_ref: refs/heads/main
```

`repos.*.path` と `agent.workspace_root` は agent が見える path として扱う。project 固有の build、test、verification は `commands/` と `scenarios/` に置く。

## 初回セットアップ

```sh
mkdir -p "$HOME/.local/bin" "$HOME/.local/share"

docker run --rm \
  -v "$HOME/.local:/install" \
  ghcr.io/wamukat/a2o-engine:latest \
  a2o host install \
    --output-dir /install/bin \
    --share-dir /install/share/a2o \
    --runtime-image ghcr.io/wamukat/a2o-engine:latest

export PATH="$HOME/.local/bin:$PATH"
```

`a2o host install` は runtime image から host launcher と shared runtime asset を取り出す。host に Ruby runtime は要求しない。

## Project Bootstrap

reference product を使う場合:

```sh
a2o project bootstrap --package ./reference-products/typescript-api-web/project-package
a2o kanban up
a2o kanban doctor
a2o kanban url
a2o agent install --target auto --output ./.work/a2o-agent/bin/a2o-agent
a2o runtime run-once
a2o runtime start
```

bootstrap 後は、カレント workspace の runtime instance config を `a2o` が探索する。通常操作で `--package` を毎回指定しない。

## Reference Products

A2O は次の sample product を持つ。

| Product | Package | Use case |
|---|---|---|
| TypeScript API/Web | `reference-products/typescript-api-web/project-package/` | API and Web UI |
| Go API/CLI | `reference-products/go-api-cli/project-package/` | HTTP API and CLI |
| Python Service | `reference-products/python-service/project-package/` | Python service |
| Multi-repo Fixture | `reference-products/multi-repo-fixture/project-package/` | parent-child and cross-repo flow |

自分の product package を作る前に、近い形の reference package をコピーして不要な scenario と command を削る。

## Kanban Operation

```sh
a2o kanban up
a2o kanban doctor
a2o kanban url
```

`doctor` は kanban service と runtime config の接続確認に使う。`url` は browser で開く board URL を表示する。

## Agent Operation

通常は `a2o agent install` で `a2o-agent` を project dev-env または host に置く。

```sh
a2o agent install --target auto --output ./.work/a2o-agent/bin/a2o-agent
```

agent は project toolchain がある場所で動かす。たとえば Node product なら `node` と `npm`、Go product なら `go`、Python product なら `python3` が agent 側に必要である。必要な binary は `project.yaml` の `agent.required_bins` に書く。

## Task Scenario

scenario は `project-package/scenarios/` に置く。scenario は kanban task として作成できる粒度にする。

よい scenario:

- small source change
- deterministic test command
- clear acceptance criteria
- repo label or trigger label included
- generated/cache file boundary documented

避ける scenario:

- product-wide rewrite
- unclear acceptance criteria
- local machine path dependency
- manual-only verification

## Runtime Execution

A2O は、task を kanban に置いた後、公開 command で implementation、verification、merge、evidence 記録まで進める。

一回だけ実行する場合:

```sh
a2o runtime run-once
```

foreground で繰り返し実行する場合:

```sh
a2o runtime loop --interval 60s
```

常駐 scheduler として自動実行する場合:

```sh
a2o runtime start --interval 60s
a2o runtime status
a2o runtime stop
```

状態確認:

```sh
a2o runtime doctor
```

標準操作は次の流れである。

1. `a2o kanban url` で board を開く。
2. `project-package/scenarios/` をもとに task を作成する。
3. task に trigger label と repo label を付ける。
4. `a2o runtime start` で常駐 scheduler を開始する。focused validation では `a2o runtime run-once` または `a2o runtime loop` を使う。
5. A2O が workspace を作成し、`a2o-agent` に implementation / verification / merge job を渡す。
6. A2O が kanban comment、phase transition、evidence、branch publication を記録する。
7. task が `Done` または `Blocked` になったことを board と evidence で確認する。

利用者は `execute-until-idle` の引数、agent control plane、workspace materializer、merge runner を直接組み立てない。

`runtime loop` は前景プロセスであり、terminal や CI job が生きている間だけ動く。通常運用では `runtime start` / `status` / `stop` を使う。

## Multi-repo Package

multi-repo package は repo slot を複数持つ。

```yaml
repos:
  repo_alpha:
    path: ../repos/catalog-service
    role: product
    label: repo:catalog
  repo_beta:
    path: ../repos/storefront
    role: product
    label: repo:storefront
```

task は repo label を使って対象 slot を指定する。parent-child flow では child が各 repo の作業を進め、parent が統合 review、verification、merge を担当する。

## 現在の注意点

- Full runtime execution は `a2o runtime start` / `stop` / `status` または focused validation 用の `a2o runtime run-once` / `loop` で開始できる。
- runtime state には内部互換名が残る場合がある。通常の manual では編集対象にしない。
- project package の公開 config は `project.yaml` に一本化されている。`manifest.yml` はサポート対象外である。
- published image での release smoke は、公開前の独立した gate として digest 固定で実行する。

残る user-facing diagnostics の整理は `A2O#270` で追跡する。`A2O#269` は single-file schema proposal を扱う。
