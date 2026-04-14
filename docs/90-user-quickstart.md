# A3 User Quickstart

対象読者: A3 利用者 / project maintainer
文書種別: 利用手順 / 配布設計

この文書は、A3 を利用する側が何を用意し、どのコマンドを実行するかを示す。A3 開発者向けの内部設計ではなく、A3 release を受け取って project に導入する人の視点で書く。

## 基本方針

A3 利用者に長い shell script を書かせない。

利用者が作るものは project package であり、実行ロジックではない。Docker compose 起動、A3 Engine command、agent package export、agent control plane、runtime loop、agent polling loop は A3 側の release surface が持つ。

利用者が意識する入口は次の 2 種類に絞る。

- `a3 runtime ...`: A3 Engine / SoloBoard / runtime loop を操作する。
- `a3-agent ...`: project runtime 側で job を pull して実行する。通常は `a3 runtime run-once` または `a3 runtime loop` が起動補助するため、手動で直接叩く頻度は低い。

A3 runtime は、現行設計では「1 project package = 1 runtime instance」として扱う。1つの Engine instance に複数 project を登録して `--project NAME` で切り替える registry 型ではない。複数 project を同時に動かす場合は、project package ごとに compose project name / storage dir / port / workspace root を分けた別 runtime instance として起動する。

`a3 project bootstrap --package ./a3-project` は、カレント workspace に A3 runtime instance config を作成する。bootstrap 後の通常操作では package path を毎回指定しない。`a3 runtime ...` と `a3 agent install` は、カレントディレクトリから上方向に instance config を探索して、対象 package と runtime instance を解決する。runtime instance の compose project name を branch namespace として注入するため、isolated board で同じ `Portal#1` が作られても既存 live repo の historical `a3/work/Portal-1` branch を再利用しない。

## 利用者が用意するもの

利用者が用意するのは project package である。Portal でいえば root repo の `scripts/a3-projects/portal/` に相当する。

project package は次を持つ。

- `project.yaml` または `project.json`: project 名、kanban project、repo slot、phase、trigger label、agent environment を定義する。
- `kanban/bootstrap.json`: SoloBoard の board / lane / tag 初期化設定を定義する。
- `hooks/`: project 固有の verification / remediation / bootstrap hook を置く。
- `README.md`: project package の設定値と前提 toolchain を説明する。

A3 利用者が作らないものは次である。

- A3 runtime 起動用の長い shell script。
- `execute-until-idle` の長い引数列。
- `a3 agent package export` の checksum / target 判定 glue。
- `a3-agent` の workspace materializer 設定 script。
- SoloBoard API を直接叩く wrapper。

## 最小 project package 例

```yaml
project: portal

kanban:
  provider: soloboard
  project: Portal
  bootstrap: kanban/bootstrap.json

repos:
  member-portal-starters:
    path: /Users/example/workspace/mypage-prototype/member-portal-starters
    role: support
  member-portal-ui-app:
    path: /Users/example/workspace/mypage-prototype/member-portal-ui-app
    role: product

agent:
  workspace_root: /Users/example/workspace/mypage-prototype/.work/a3-agent/workspaces
  required_bins:
    - git
    - task
    - ruby
  env:
    A3_MAVEN_WORKSPACE_BOOTSTRAP_MODE: empty

runtime:
  kanban_status: To do
  live_ref: refs/heads/feature/prototype
  max_steps: 50
  agent_attempts: 500
```

`repos.*.path` と `agent.workspace_root` は agent から見た path である。A3 Engine container から見た path ではない。

## 初回セットアップ

A3 release 後の利用者コマンドは次の形にする。

```bash
mkdir -p "$HOME/.local/bin" "$HOME/.local/share"
docker run --rm \
  -v "$HOME/.local:/install" \
  docker.io/<org>/a3-engine:latest \
  a3 host install \
    --output-dir /install/bin \
    --share-dir /install/share/a3 \
    --runtime-image docker.io/<org>/a3-engine:latest
export PATH="$HOME/.local/bin:$PATH"

a3 project bootstrap --package ./a3-project
a3 runtime up
a3 agent install --target auto --output ./.work/a3-agent/bin/a3-agent
a3 runtime doctor
```

`a3 host install` は Docker image に同梱された Go host launcher と A3 配布 asset を host へコピーする。container 内の Ruby Engine CLI は host に出ない。host 側の `$HOME/.local/bin/a3` は POSIX shell wrapper で、`uname` により `a3-darwin-amd64` / `a3-linux-amd64` などの platform binary を選んで実行する。標準 compose file は `$HOME/.local/share/a3` 配下へ配置される。Docker から export するため、`bin` だけではなく `$HOME/.local` のような install prefix を mount する。`--runtime-image` は後続の `a3 runtime ...` が起動する Engine image を記録する。

`a3 agent install` は Engine image に同梱された `a3-agent` release binary を host または project dev-env へ export する。利用者に Go toolchain や Ruby interpreter を要求しない。

## 日常実行

手動で 1 cycle だけ流す場合は次だけにする。

```bash
a3 runtime run-once
```

繰り返し動かす場合は次にする。

```bash
a3 runtime loop
```

`run-once` は、kanban から対象 task を選び、必要な agent job を queue し、`a3-agent` に実行させ、結果を A3 state / artifact store / kanban に反映する。利用者は `execute-until-idle` の詳細引数を直接組み立てない。

## 手動 agent 起動が必要な場合

通常は A3 runtime command が agent の install / doctor / one-shot 起動を補助する。ただし、project dev-env container の中で agent を常駐させたい場合は、利用者が次のように起動してよい。

```bash
a3-agent --engine http://localhost:7393 --loop --poll-interval 2s
```

この場合でも repo path、workspace root、required bins は agent local profile ではなく、Engine 側 project package から job payload として渡す。

## Portal での現状

現時点の Portal workspace では、`a3 project bootstrap` / `a3 runtime up` / `a3 agent install` / `a3 runtime run-once` は実装済みで、A3 Engine runtime image から host/dev-env 用 `a3-agent` を export できる。

```bash
a3 project bootstrap --package ./scripts/a3-projects/portal
a3 runtime up
a3 agent install --target auto --output ./.work/a3-agent/bin/a3-agent
a3 runtime run-once
```

root Taskfile の互換入口も残っている。

```bash
task a3:portal:runtime:up
task a3:portal:runtime:doctor
task a3:portal:runtime:run-once
task a3:portal:runtime:watch-summary
```

ただし、現時点の `a3 runtime run-once` は project package の `runtime/run_once.sh` を A3 launcher から呼ぶ互換実装である。利用者は script を直接叩かないが、後続実装で A3 Engine の generic `a3 runtime run-once` command に吸収する。

## 残タスク

- `a3 runtime loop` は A3 Engine の release command として実装済み。現時点では `run-once` を interval 実行する最小 loop であり、stale recovery / retention cleanup の cycle hook は後続 hardening として扱う。
- project package loader と runtime instance config を実装し、root Taskfile 依存を release surface から外す。`a3 project bootstrap --package ./a3-project` 後は package 指定不要とし、multi-project registry に見える `--project NAME` は標準入口にしない。
- `a3 agent install` は release artifact に含め、runtime image から host/dev-env への binary export を利用者向け配布物として固定済み。release 前には正式 image ref で同手順を再 smoke する。
- `scripts/a3-projects/portal/runtime/run_once.sh` の責務を A3 Engine command へ移し、Portal 側を thin config package にする。現時点の `a3 runtime run-once` はこの script を隠蔽する互換入口である。
- `A3_RUNTIME_RUN_ONCE_*` のような内部 env は project package / CLI option に寄せ、利用者の主要入口から隠す。
- A3/SoloBoard compose file は A3 配布物として同梱し、project package 側に compose file 作成を要求しない。compose override は開発・診断用に限定する。
- Docker Hub / GHCR の正式 image ref が決まったら、この README の `docker.io/<org>/a3-engine:latest` placeholder を置換する。
