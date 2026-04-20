# Quickstart

この文書は、A2O を初めて導入し、kanban task を 1 つ A2O に処理させるまでの最短手順を説明する。全体像は先に [00-overview.md](00-overview.md) を読む。

## この手順で到達する状態

| Step | 達成すること |
|---|---|
| Host launcher install | host から `a2o` command を実行できる |
| Project package setup | A2O が product repository、skill、command、kanban board を読める |
| Runtime bootstrap | `.work/a2o/runtime-instance.json` に runtime instance を作る |
| Kanban up | A2O 用 board、lane、internal label を用意する |
| Agent install | product 環境で job を実行する `a2o-agent` を配置する |
| Task pickup | kanban task を A2O が拾い、結果を board / Git / evidence に残す |

## 前提

- Docker が使える。
- Product repository がある。
- A2O 用の project package を repository root に置ける。
- `a2o-agent` を実行する環境に product toolchain と AI executor command を用意できる。

Executor command は、実際に agent 環境で実行できる binary に置き換える。Template の `your-ai-worker` のままでは `a2o doctor` または runtime execution で止まる。

## 1. Host launcher を入れる

```sh
mkdir -p "$HOME/.local/bin" "$HOME/.local/share"

docker run --rm \
  -v "$HOME/.local:/install" \
  ghcr.io/wamukat/a2o-engine:0.5.5 \
  a2o host install \
    --output-dir /install/bin \
    --share-dir /install/share/a2o \
    --runtime-image ghcr.io/wamukat/a2o-engine:0.5.5

export PATH="$HOME/.local/bin:$PATH"
```

`a2o host install` は runtime image から host launcher と shared runtime asset を取り出す。Host に Ruby runtime は要求しない。

`docker run ... a2o --help` は runtime container entrypoint の help であり、host launcher の全 command 一覧ではない。以後は install 済みの `a2o` を使う。

## 2. Project package を作る

Workspace root に `project-package/` を置く。この quickstart では、この directory を標準 package path として扱う。

```text
project-package/
  README.md
  project.yaml
  commands/
  skills/
  task-templates/
```

新規 package は template から始める。

```sh
a2o project template \
  --package-name my-product \
  --kanban-project MyProduct \
  --language node \
  --executor-bin your-ai-worker \
  --with-skills \
  --output ./project-package/project.yaml
```

この command は `project.yaml` と starter skill files を作る。作成後に `your-ai-worker` を実際の executor command に置き換える。

Package の考え方は [20-project-package.md](20-project-package.md)、schema 詳細は [90-project-package-schema.md](90-project-package-schema.md) を読む。

## 3. Package を確認する

```sh
a2o project lint --package ./project-package
```

`project lint` は `project.yaml`、command file、test fixture 参照、user-facing に漏れた internal name を確認する。`blocked` finding は runtime 実行前に直す。

Focused test profile を使う場合だけ、明示的に config を指定して確認する。

```sh
a2o project validate --package ./project-package --config project-test.yaml
```

通常の `project.yaml` は production-oriented に保つ。

## 4. Runtime instance を作る

```sh
a2o project bootstrap
```

`project bootstrap` は `.work/a2o/runtime-instance.json` を作る。以後の `kanban`、`agent`、`runtime` command はこの instance config を見つけて同じ runtime instance を使う。

Port、compose project を変えたい場合だけ option を指定する。

```sh
a2o project bootstrap --compose-project my-product --soloboard-port 3471 --agent-port 7394
```

## 5. Kanban を起動する

```sh
a2o kanban up
a2o kanban url
```

`kanban up` は bundled kanban service を起動し、A2O が必要とする lane と internal label を用意する。`kanban url` は board URL を表示する。

同じ compose project なら既存 board を再利用する。Board が空に見える場合は compose project / Docker volume が変わっていないか確認する。運用の詳細は [30-operating-runtime.md](30-operating-runtime.md) を読む。

## 6. Agent を install する

```sh
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
```

`a2o-agent` は product 環境で executor command、product toolchain、生成AI呼び出しを実行する。既定の配置先は `.work/a2o/agent/bin/a2o-agent` である。

次に全体診断を行う。

```sh
a2o doctor
```

`status=blocked` の check がある場合は、表示された `action=` を先に直す。

## 7. Task を 1 つ作る

1. `a2o kanban url` で board を開く。
2. `project-package/task-templates/` をもとに task を作る。
3. task を `project.yaml` の `kanban.selection.status` に置く。既定は `To do`。
4. task に trigger label と、必要なら repo label を付ける。

`a2o kanban up` は lane と label を用意するが、作業 task は自動投入しない。

## 8. A2O に実行させる

初回確認では 1 cycle だけ実行する。

```sh
a2o runtime run-once
```

常駐 scheduler として動かす場合は次を使う。

```sh
a2o runtime start --interval 60s
a2o runtime status
a2o runtime stop
```

`runtime start` は task processing を自動開始する。Container lifecycle だけを扱いたい場合は `a2o runtime up` / `a2o runtime down` を使う。

## 9. 結果を確認する

```sh
a2o runtime watch-summary
a2o runtime describe-task <task-ref>
```

`watch-summary` は board 上の複数 task、scheduler state、running phase をまとめて見る。`describe-task` は 1 task の run、evidence、kanban comment、log hint を表示する。

Task に agent execution artifact がある場合、`describe-task` は `agent_artifact_read` command を表示する。

```sh
a2o runtime show-artifact <artifact-id>
```

Board 上の `Done` は A2O automation が完了した状態である。SoloBoard の `Resolved` / `done=true` は人間の最終確認を表す別状態である。

## 問題が起きたら

まず次を見る。

```sh
a2o doctor
a2o runtime watch-summary
a2o runtime describe-task <task-ref>
```

Error category、agent artifact、blocked task の復旧手順は [40-troubleshooting.md](40-troubleshooting.md) にまとめている。

## 次に読む文書

| 目的 | 文書 |
|---|---|
| project package の設計を理解する | [20-project-package.md](20-project-package.md) |
| runtime / kanban / agent / image update を運用する | [30-operating-runtime.md](30-operating-runtime.md) |
| blocked / failed task を調査する | [40-troubleshooting.md](40-troubleshooting.md) |
| multi-repo / parent-child flow を使う | [50-parent-child-task-flow.md](50-parent-child-task-flow.md) |
| `project.yaml` の詳細を見る | [90-project-package-schema.md](90-project-package-schema.md) |
