# Operating Runtime

この文書は、A2O を日常運用するときに使う command と見るべき状態を説明する。初回 setup は [10-quickstart.md](10-quickstart.md)、package の作り方は [20-project-package.md](20-project-package.md)、問題対応は [40-troubleshooting.md](40-troubleshooting.md) を読む。

## Runtime の構成

A2O の通常運用は、次の 4 つで構成される。

| 構成要素 | 役割 | 主な command |
| --- | --- | --- |
| Host launcher `a2o` | host から runtime image と instance を操作する | `a2o project bootstrap`, `a2o kanban ...`, `a2o runtime ...` |
| A2O Engine | kanban task を選び、phase job を作り、結果を記録する | `a2o runtime up`, `a2o runtime start`, `a2o runtime status` |
| a2o-agent | product 環境で job を実行し、Git repository を変更・検証する | `a2o agent install` |
| Project package | project 固有の repo、skill、command、phase を定義する | `a2o project lint` |

Runtime instance は project package から作る。Bootstrap 後、`a2o kanban ...`、`a2o agent install`、`a2o runtime ...` は `.work/a2o/runtime-instance.json` を見つけて同じ instance を使う。

```sh
a2o project bootstrap
```

Package を標準 path 以外に置く場合だけ、明示的に指定する。

```sh
a2o project bootstrap --package ./path/to/project-package
```

## 日常操作

通常は、kanban を起動し、agent を配置し、scheduler を開始する。

```sh
a2o kanban up
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
a2o runtime up
a2o runtime start --interval 60s
```

状態確認には次を使う。

```sh
a2o runtime status
a2o runtime watch-summary
```

`runtime status` は scheduler、runtime container、kanban、image digest、latest run status を見る。`runtime watch-summary` は task 一覧の現在位置を見る。

特定 task を深く見る場合は `describe-task` を使う。

```sh
a2o runtime describe-task <task-ref>
```

`describe-task` は run、phase、workspace、evidence、kanban comment、log hint、agent artifact の読み方をまとめて表示する。

## Scheduler と手動実行

通常運用では resident scheduler を使う。

```sh
a2o runtime start --interval 60s
a2o runtime status
a2o runtime stop
```

`runtime start` は task processing を常駐実行する。`runtime stop` は scheduler を止める。`runtime status` は scheduler が動いているか、runtime image が期待通りか、latest run がどう終わったかを確認する。

`runtime run-once` は手動確認や検証用である。Scheduler を使う前に 1 回だけ pickup したいときや、問題を直した後に再同期したいときに使う。

```sh
a2o runtime run-once
```

Container lifecycle だけを扱う場合は `runtime up` / `down` を使う。これらは scheduler を開始しない。

```sh
a2o runtime up
a2o runtime down
```

## Kanban 運用

Kanban は A2O Engine が task を読む入口である。

```sh
a2o kanban up
a2o kanban doctor
a2o kanban url
```

`kanban up` は bundled kanban service を起動し、A2O が必要とする lane と internal label を用意する。利用者は A2O-owned lane や internal label を project package に手書きしない。

同じ compose project なら既存 board を再利用する。Compose project や Docker volume が変わると、同じ product でも別 board に見える。Board が空に見える場合は、まず `a2o runtime status` と `a2o kanban doctor` で instance config、compose project、volume を確認する。

## Agent 運用

a2o-agent は、A2O Engine から渡された job を product 環境で実行する binary である。標準配置先は `.work/a2o/agent/bin/a2o-agent` である。

```sh
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
```

Agent が使う workspace、materialized data、launcher config は `.work/a2o/agent/` 配下に閉じる。Product repository root に generated runtime file が出る状態は避ける。

Agent が job を実行できるように、project package の `agent.required_bins` には product toolchain と AI worker executable を書く。`your-ai-worker` のような placeholder が残っていると、`a2o doctor` または runtime execution で止まる。

## Image update と digest 確認

新しい runtime image を使う前に、check-only で差分を見る。

```sh
a2o upgrade check
a2o runtime image-digest
```

`upgrade check` は pull、restart、file edit をしない。Host launcher version、bootstrapped instance config、runtime image digest、agent install status、次に実行すべき command を表示する。

Image を取得して runtime を再起動する。

```sh
a2o runtime up --pull
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
a2o doctor
a2o runtime status
```

`runtime image-digest` は configured pinned ref、local latest ref、running container ref を比較する。Mismatch が出た場合は、使う image を確認してから `a2o runtime up` で再起動する。

## 診断 command

問題があるときは、広い診断から狭い診断へ進む。

| 見たいこと | Command |
| --- | --- |
| package、agent、kanban、runtime、image をまとめて見る | `a2o doctor` |
| runtime container と scheduler を見る | `a2o runtime status` |
| runtime 専用の診断を見る | `a2o runtime doctor` |
| kanban service と board を見る | `a2o kanban doctor` |
| task 一覧の進行状況を見る | `a2o runtime watch-summary` |
| 1 task の run/evidence/log を見る | `a2o runtime describe-task <task-ref>` |

Blocked task、dirty repo、executor failure、verification failure などの症状別対応は [40-troubleshooting.md](40-troubleshooting.md) を読む。
