# A2O User Manual

対象読者: A2O 利用者 / project maintainer
文書種別: 利用手順

A2O は kanban task を起点に、workspace 作成、agent 実行、検証、merge、evidence 記録を進める automation engine である。利用者は project package を用意し、A2O の公開コマンドで runtime を起動する。

## Getting Started

### 1. Host launcher を入れる

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

### 2. Project package を置く

workspace root に `project-package/` または `a2o-project/` を置く。

```text
project-package/
  README.md
  project.yaml
  kanban/bootstrap.json
  commands/
  skills/
  scenarios/
```

新規 package は template から始める。

```sh
a2o project template \
  --package-name my-product \
  --kanban-project MyProduct \
  --language node \
  --executor-bin your-ai-worker \
  --output ./project-package/project.yaml
```

`--output` を使うと、A2O は `project.yaml` と同時に `kanban/bootstrap.json` も生成する。既存ファイルは `--force` なしでは上書きしない。生成される bootstrap file は repo label など project 固有 label だけを持つ。A2O が必要とする lane と internal label は `a2o kanban up` が用意する。

`your-ai-worker` は placeholder である。bootstrap や runtime 実行の前に、agent 環境で実行できる executor binary 名へ置き換える。A2O はこの値を `agent.required_bins` と `runtime.executor.command` に書くため、未置換のままだと `a2o doctor` や runtime execution で missing command として止まる。

### 3. 最小 4 コマンドで起動する

project package を置いた後の最小手順:

```sh
a2o project bootstrap
a2o kanban up
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
a2o runtime run-once
```

`a2o project bootstrap` は `.work/a2o/runtime-instance.json` を作り、後続の `kanban`、`agent`、`runtime` command が同じ runtime instance を使えるようにする。`a2o agent install` は既定で `.work/a2o/agent/bin/a2o-agent` に agent を配置する。

`run-once` の前に、board 上に runnable task を 1 つ用意する。`kanban/bootstrap.json` は lane と tag を作るが、作業 task は自動投入しない。

1. `a2o kanban url` で board を開く。
2. `project-package/scenarios/` の内容をもとに task を作成する。
3. task を `project.yaml` の `kanban.selection.status` に置く。既定は `To do`。
4. task に trigger label と、必要なら repo label を付ける。

board URL は次で確認する。

```sh
a2o kanban url
```

task の状態、run、evidence、kanban comment、見るべき log は次で確認する。

```sh
a2o runtime describe-task <task-ref>
```

## Configuration

### project.yaml

`project.yaml` は project package の唯一の公開 config である。A2O は package metadata、kanban bootstrap、repo slot、agent prerequisites、runtime surface command、merge default をここから読む。

最小構成では single repo、single merge target、one executor から始める。

```yaml
schema_version: 1
package:
  name: my-product
kanban:
  project: MyProduct
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

`agent.required_bins` には agent 環境で必要な binary を書く。Node product なら `node` と `npm`、Go product なら `go`、Python product なら `python3`、executor が使う AI CLI や helper binary も含める。

### Generated files

新規 `a2o project bootstrap` は runtime instance config を `.work/a2o/runtime-instance.json` に書く。`a2o agent install` と runtime execution で生成される host agent、launcher config、agent workspace も原則 `.work/a2o/` 配下に置く。

`.work/a2o/` は A2O が再生成できる runtime output であり、通常は version control に入れない。利用者が管理するのは project package、product source、Taskfile などである。

旧バージョンの runtime instance config は互換のため読み取る。ただし新規 bootstrap は旧ディレクトリに instance config を書かない。materialized workspace 内の agent metadata は利用者が編集する設定ではない。

## Operations

### Kanban

```sh
a2o kanban up
a2o kanban doctor
a2o kanban url
```

`a2o kanban up` は、利用する `compose_project`、SoloBoard data volume、reuse / create mode、backup hint を表示する。同じ compose project で起動すると既存 board を再利用する。compose project が変わると Docker volume 名も変わるため、board が空に見える。

SoloBoard bootstrap では、A2O が必要とする lane と internal label が自動作成される。project package の `kanban/bootstrap.json` には、repo label や人間が使う分類 label など、project 固有の label だけを書く。

fresh board を意図する場合は、bootstrap 時に別の compose project を指定するか、既存 volume を backup して明示的に削除してから起動する。誤って既存 board を使いたくない場合は `a2o kanban up --fresh-board` を使う。既存 volume がある場合、この command は停止する。

### Agent

```sh
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
a2o doctor
```

`a2o agent install` は runtime image から host 用 `a2o-agent` を取り出す。canonical path は `.work/a2o/agent/bin/a2o-agent` である。`a2o doctor` は release-readiness の一括診断で、project package、executor config、required command、repo clean 状態、agent install、kanban volume / service、runtime container、runtime image digest を確認する。問題がある check は `status=blocked` と `action=...` を出す。

### Task

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

### Runtime

container を起動または更新する場合:

```sh
a2o runtime up
a2o runtime down
```

`runtime up/down` は container lifecycle だけを扱う。scheduler は開始しない。

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

`runtime start/stop/status` は scheduler lifecycle の command である。`runtime start` は task processing を自動開始するため、container refresh だけが目的なら `runtime up` を使う。`runtime status` は scheduler 状態に加えて、runtime container、kanban service、kanban URL、runtime image digest、project package、latest run summary をまとめて表示する。

状態確認:

```sh
a2o runtime doctor
a2o runtime describe-task <task-ref>
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

## Troubleshooting

A2O の CLI stderr と kanban comment は、失敗時に `error_category` / `エラー分類` と remediation を出す。最初に分類を見て、次に `a2o runtime describe-task <task-ref>` で task/run/evidence/comment/log を確認する。

| Category | What to fix |
|---|---|
| `configuration_error` | `project.yaml`、executor、package path、schema を直す。generated `launcher.json` は編集しない。 |
| `workspace_dirty` | 表示された repo / file の未コミット変更を commit、stash、または削除する。 |
| `executor_failed` | executor binary、認証、必要 toolchain、worker result JSON を確認する。 |
| `verification_failed` | verification / remediation command の出力を見て product test、lint、依存関係を直す。 |
| `merge_conflict` | merge conflict または base branch を整理する。 |
| `merge_failed` | merge target ref と branch policy を確認する。 |
| `runtime_failed` | Docker / compose / runtime process の状態と出力を確認する。 |

診断の入口:

```sh
a2o doctor
a2o kanban doctor
a2o runtime doctor
a2o runtime describe-task <task-ref>
```

`a2o doctor` は primary diagnostic である。project package、executor config、required command、repo clean 状態、agent install、kanban volume / service、runtime container、runtime image digest をまとめて確認する。`status=blocked` の check は `action=` に次の操作を出す。既存 kanban volume の reuse など正常な情報は `status=ok` / `action=none` として表示する。`a2o kanban doctor` と `a2o runtime doctor` は focused inspection 用に使う。

User-facing diagnostics は A2O/project.yaml の語彙に寄せる。内部互換名が必要な場合も、通常の導入手順では編集対象として扱わない。

## Advanced Examples

### Package path / port / compose project を指定する

project package が `./project-package` または `./a2o-project` 以外にある場合や、port / compose project を分ける場合だけ option を指定する。

```sh
a2o project bootstrap --package ./reference-products/typescript-api-web/project-package
a2o project bootstrap --package ./project-package --compose-project my-product --soloboard-port 3471 --agent-port 7394
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
a2o doctor
a2o runtime up
a2o runtime start --interval 60s
```

### Reference products

A2O は次の sample product を持つ。

| Product | Package | Use case |
|---|---|---|
| TypeScript API/Web | `reference-products/typescript-api-web/project-package/` | API and Web UI |
| Go API/CLI | `reference-products/go-api-cli/project-package/` | HTTP API and CLI |
| Python Service | `reference-products/python-service/project-package/` | Python service |
| Multi-repo Fixture | `reference-products/multi-repo-fixture/project-package/` | parent-child and cross-repo flow |

自分の product package を作る前に、近い形の reference package をコピーして不要な scenario と command を削る。

### Multi-repo package

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

## Runtime Image Updates

A2O の runtime image は、導入検証では `ghcr.io/wamukat/a2o-engine:latest` を使ってよい。実 product package、release smoke、複数人が同じ board / package を使う環境では digest pinning を使う。tag は動く参照であり、digest は同じ image を再現する参照である。

推奨手順:

```sh
a2o runtime up --pull
a2o runtime image-digest
a2o doctor
```

`a2o runtime image-digest` が出した `runtime_image_digest=...` を project package の Taskfile / env file / deployment note の runtime image 値に反映する。更新後は次を確認する。

```sh
a2o runtime down
a2o runtime up
a2o runtime status
a2o doctor
```

package 側では runtime image 値を 1 箇所に寄せる。Taskfile を使う場合は `A2O_RUNTIME_IMAGE` に digest を置く。A2O launcher は `A2O_RUNTIME_IMAGE` を読み取り、compose 実行時の runtime image として使う。test expectation に digest を直接複数箇所へ書かない。既存 product package を更新する場合も、`a2o runtime image-digest` の出力を source of truth として Taskfile と smoke test expectation を同時に更新する。

`latest` を使ってよい場面:

- local trial
- reference project の短い動作確認
- digest を採取する前の一時起動

digest pinning が必要な場面:

- release smoke
- 実 product package の共有運用
- CI / regression validation
- 利用者へ再現手順を案内する場合

## Known Gaps

- `project.yaml` のさらに短い guided bootstrap は未実装である。導入時の候補生成は backlog の feature として扱う。
- runtime state には内部互換名が残る場合がある。通常の manual では編集対象にしない。
