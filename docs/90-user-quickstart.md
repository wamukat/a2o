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
mkdir -p "$HOME/.local/bin"
docker run --rm \
  -v "$HOME/.local/bin:/out" \
  docker.io/<org>/a3-engine:latest \
  a3 host install --output-dir /out
export PATH="$HOME/.local/bin:$PATH"

a3 project bootstrap --package ./a3-project
a3 runtime up --package ./a3-project
a3 agent install --target auto --output ./.work/a3-agent/bin/a3-agent
a3 runtime doctor --package ./a3-project
```

`a3 host install` は Docker image に同梱された Go host launcher を host へコピーする。container 内の Ruby Engine CLI は host に出ない。host 側の `$HOME/.local/bin/a3` は POSIX shell wrapper で、`uname` により `a3-darwin-amd64` / `a3-linux-amd64` などの platform binary を選んで実行する。

`a3 agent install` は Engine image に同梱された `a3-agent` release binary を host または project dev-env へ export する。利用者に Go toolchain や Ruby interpreter を要求しない。

## 日常実行

手動で 1 cycle だけ流す場合は次だけにする。

```bash
a3 runtime run-once --package ./a3-project
```

繰り返し動かす場合は次にする。

```bash
a3 runtime loop --package ./a3-project
```

`run-once` は、kanban から対象 task を選び、必要な agent job を queue し、`a3-agent` に実行させ、結果を A3 state / artifact store / kanban に反映する。利用者は `execute-until-idle` の詳細引数を直接組み立てない。

## 手動 agent 起動が必要な場合

通常は A3 runtime command が agent の install / doctor / one-shot 起動を補助する。ただし、project dev-env container の中で agent を常駐させたい場合は、利用者が次のように起動してよい。

```bash
a3-agent --engine http://localhost:7393 --loop --poll-interval 2s
```

この場合でも repo path、workspace root、required bins は agent local profile ではなく、Engine 側 project package から job payload として渡す。

## Portal での現状

現時点の Portal workspace では、`a3 agent install` は実装済みで、A3 Engine runtime image から host/dev-env 用 `a3-agent` を export できる。runtime orchestration の暫定入口は root Taskfile の次である。

```bash
cd a3-engine/agent-go
go run ./cmd/a3 agent install \
  --target auto \
  --output /tmp/a3-agent-user-check \
  --build
```

runtime orchestration の暫定入口は root Taskfile の次である。

```bash
task a3:portal:runtime:up
task a3:portal:runtime:doctor
task a3:portal:runtime:run-once
task a3:portal:runtime:watch-summary
```

ただし、`task a3:portal:runtime:run-once` の裏側にはまだ Portal 固有 launcher が残っている。現在の配置は `scripts/a3-projects/portal/runtime/run_once.sh` であり、これは利用者に複製させる script ではない。後続実装で A3 Engine の generic `a3 runtime run-once` command に吸収する。

## 残タスク

- `a3 runtime up/down/doctor/run-once/loop` を A3 Engine の release command として実装する。
- project package loader を実装し、root Taskfile 依存を release surface から外す。runtime command は `--package ./a3-project` を正規入口とし、multi-project registry に見える `--project NAME` は標準入口にしない。
- `a3 agent install` を release artifact に含め、runtime image から host/dev-env への binary export を利用者向け配布物として固定する。
- `scripts/a3-projects/portal/runtime/run_once.sh` の責務を A3 Engine command へ移し、Portal 側を thin config package にする。
- `A3_RUNTIME_RUN_ONCE_*` のような内部 env は project package / CLI option に寄せ、利用者の主要入口から隠す。
- A3/SoloBoard compose file は A3 配布物として同梱し、project package 側に compose file 作成を要求しない。compose override は開発・診断用に限定する。
