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

新規 package は手書きから始めず、まず template を生成する。

```sh
a2o project template \
  --package-name my-product \
  --kanban-project MyProduct \
  --language node \
  --executor-bin your-ai-worker \
  --output ./project-package/project.yaml
```

`--language` は `generic`、`node`、`go`、`python`、`ruby` を選べる。A2O は選択した toolchain と `--executor-bin` を `agent.required_bins` に入れる。

`--output` を使うと、A2O は `project.yaml` と同時に `kanban/bootstrap.json` も生成する。既存ファイルは `--force` なしでは上書きしない。既存 package の移行で比較用に出す場合は、別ディレクトリか stdout 出力を使う。

生成される `runtime.executor.command` は、A2O が agent に渡す stdin bundle を executor command へ接続する短縮記法である。通常は `--executor-bin` を自分の worker CLI に変えるところから始める。worker CLI が標準の `--schema {{schema_path}} --result {{result_path}}` 以外の引数を使う場合は、`--executor-arg` を繰り返して command array を生成する。

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
  workspace_root: .work/a2o/agent/workspaces
  required_bins:
    - git
    - node
    - npm
    - your-ai-worker
runtime:
  live_ref: refs/heads/main
  max_steps: 20
  agent_attempts: 200
  executor:
    command:
      - your-ai-worker
      - "--schema"
      - "{{schema_path}}"
      - "--result"
      - "{{result_path}}"
    phase_profiles: {}
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

`runtime.executor.command` は implementation / review を実行する agent 側 command である。A2O は worker request を stdin bundle として渡し、executor は `{{result_path}}` に worker result JSON を書く。`{{schema_path}}`、`{{result_path}}`、`{{workspace_root}}`、`{{a2o_root_dir}}`、`{{root_dir}}` を command placeholder として使える。

`repos.*.path` と `agent.workspace_root` は agent が見える path として扱う。project 固有の build、test、verification は `commands/` と `scenarios/` に置く。

複数 repo、support repo、local dependency cache、parent/child flow を持つ package は advanced example として扱う。最初の package では single repo、single merge target、one executor から始める。

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

## 最小起動

project package を workspace root の `project-package/` または `a2o-project/` に置いた後の最小手順:

```sh
a2o project bootstrap
a2o kanban up
a2o agent install
a2o runtime run-once
```

bootstrap 後は、カレント workspace の runtime instance config を `a2o` が探索する。`a2o agent install` は既定で `.work/a2o/agent/bin/a2o-agent` に agent を配置する。

board を開く場合は `a2o kanban url` を使う。runtime 実行後の task 状態、run、evidence、kanban comment、log 導線は `a2o runtime describe-task <task-ref>` で確認する。

## Advanced Setup

project package が別の場所にある場合や、port / compose project を分ける場合だけ option を指定する。

```sh
a2o project bootstrap --package ./reference-products/typescript-api-web/project-package
a2o project bootstrap --package ./project-package --compose-project my-product --soloboard-port 3471 --agent-port 7394
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
a2o doctor
a2o runtime start --interval 60s
```

`a2o doctor` は release-readiness の一括診断である。日常の最小導入手順には必須ではないが、公開前や runtime が期待通り動かないときに使う。

## Generated Files

新規 `a2o project bootstrap` は runtime instance config を `.work/a2o/runtime-instance.json` に書く。`a2o agent install` と runtime execution で生成される host agent、launcher config、agent workspace も原則 `.work/a2o/` 配下に置く。

`.work/a2o/` は A2O が再生成できる runtime output であり、通常は version control に入れない。利用者が管理するのは project package、product source、Taskfile などである。

既存 workspace に `.a3/runtime-instance.json` がある場合、A2O は互換のため読み取る。ただし新規 bootstrap は `.a3/` に instance config を書かない。materialized workspace 内の `.a3/` は agent metadata であり、利用者が編集する設定ではない。

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

`a2o kanban up` は、利用する `compose_project`、SoloBoard data volume、reuse / create mode、backup hint を表示する。同じ compose project で起動すると既存 board を再利用する。compose project が変わると Docker volume 名も変わるため、board が空に見える。

fresh board を意図する場合は、bootstrap 時に別の compose project を指定するか、既存 volume を backup して明示的に削除してから起動する。誤って既存 board を使いたくない場合は `a2o kanban up --fresh-board` を使う。既存 volume がある場合、この command は停止する。

backup は `a2o kanban up` の `kanban_backup_hint` を使う。手動で確認する場合の volume 名は `<compose_project>_soloboard-data` である。

`a2o kanban doctor` は kanban service と runtime config の接続確認に絞った診断に使う。`url` は browser で開く board URL を表示する。

## Agent Operation

通常は `a2o agent install` で `a2o-agent` を project dev-env または host に置く。

```sh
a2o agent install
a2o doctor
```

agent は project toolchain と `runtime.executor` command がある場所で動かす。たとえば Node product なら `node` と `npm`、Go product なら `go`、Python product なら `python3` が agent 側に必要である。executor が使う AI CLI や helper binary も含め、必要な binary は `project.yaml` の `agent.required_bins` に書く。

`a2o doctor` は agent install 後の release-readiness 一括診断で、project package、required command、repo clean 状態、agent install、kanban volume / service、runtime image digest を確認する。問題がある check は `status=blocked` と `action=...` を出す。

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
a2o runtime describe-task <task-ref>
```

`describe-task` は runtime state、task/run の phase、workspace/ref/evidence、kanban comment、operator が次に見る log をまとめて表示する。`run-once` や `runtime start` の後、task が `Blocked` になった場合はこの command から確認する。

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

## Troubleshooting

A2O の CLI stderr と kanban comment は、失敗時に `error_category` / `エラー分類` と remediation を出す。最初に分類を見て、次に `失敗コマンド`、`観測状態`、evidence を確認する。

| Category | What to fix |
|---|---|
| `configuration_error` | `project.yaml`、executor、package path、schema を直す。generated `launcher.json` は編集しない。 |
| `workspace_dirty` | 表示された repo / file の未コミット変更を commit、stash、または削除する。 |
| `executor_failed` | executor binary、認証、必要 toolchain、worker result JSON を確認する。 |
| `verification_failed` | verification / remediation command の出力を見て product test、lint、依存関係を直す。 |
| `merge_conflict` | merge conflict または base branch を整理する。 |
| `merge_failed` | merge target ref と branch policy を確認する。 |
| `runtime_failed` | Docker / compose / runtime process の状態と出力を確認する。 |

User-facing diagnostics は A2O/project.yaml の語彙に寄せる。内部互換名が必要な場合も、通常の導入手順では編集対象として扱わない。
