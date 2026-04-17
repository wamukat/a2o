# A2O User Manual

対象読者: A2O 利用者 / project maintainer
文書種別: 利用手順

A2O は kanban task を起点に、workspace 作成、agent 実行、検証、merge、evidence 記録を進める automation engine である。利用者は project package を用意し、A2O の公開コマンドで runtime を起動する。

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
  manifest.yml
  project.yaml
  kanban/bootstrap.json
  commands/
  skills/
  scenarios/
```

`project.yaml` は runtime config である。

```yaml
project: a2o-reference-typescript-api-web
kanban:
  provider: soloboard
  project: A2OReferenceTypeScript
  bootstrap: kanban/bootstrap.json
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
  kanban_status: To do
  live_ref: refs/heads/main
  max_steps: 20
  agent_attempts: 200
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

- Full runtime execution の baseline reproduction は、まだ内部 Engine CLI を直接使う手順を含む。通常利用者向けには、これを `a2o runtime ...` 形の公開コマンドに閉じる必要がある。
- runtime state には `.a3` や `refs/heads/a3/...` など内部互換名が残る。通常の manual では編集対象にしない。
- project package schema は `manifest.yml` と `project.yaml` の責務をさらに明確化する余地がある。
- published image での release smoke は、公開前の独立した gate として実行する。

これらは A2O の設計ギャップとして `A2O#267`、`A2O#268`、`A2O#269`、`A2O#270` で追跡する。
