# A2O User Quickstart

対象読者: A2O 利用者 / project maintainer
文書種別: 利用手順 / 配布設計

この文書は、A2O (Agentic AI Orchestrator) を利用する側が何を用意し、どのコマンドを実行するかを示す。A2O 開発者向けの内部設計ではなく、A2O release を受け取って project に導入する人の視点で書く。

内部実装名は引き続き A3 である。`.a3`, `A3_*`, internal runtime state は現行 release では rename しない。公開名称と内部実装名の境界は [92-a2o-public-branding-boundary.md](92-a2o-public-branding-boundary.md) を参照する。

## 基本方針

A2O 利用者に長い shell script を書かせない。

利用者が作るものは project package であり、実行ロジックではない。Docker compose 起動、A2O Engine command、agent package export、agent control plane、runtime loop、agent polling loop は A2O 側の release surface が持つ。

利用者が意識する入口は次に絞る。

- `a2o host install`: runtime image から host launcher と配布 asset を install する。
- `a2o project bootstrap --package DIR`: project package から runtime instance config を作成する。
- `a2o kanban ...`: kanban service の起動、診断、URL 確認を操作する。
- `a2o agent install`: runtime image から host/dev-env 用 `a2o-agent` を export する。
- `a2o-agent ...`: project runtime 側で job を pull して実行する。通常利用者が直接叩く頻度は低い。

A2O runtime は、現行設計では「1 project package = 1 runtime instance」として扱う。1つの Engine instance に複数 project を登録して `--project NAME` で切り替える registry 型ではない。複数 project を同時に動かす場合は、project package ごとに compose project name / storage dir / port / workspace root を分けた別 runtime instance として起動する。

`a2o project bootstrap --package ./a2o-project` は、カレント workspace に runtime instance config を作成する。実ファイルは内部互換のため `.a3/runtime-instance.json` である。bootstrap 後の通常操作では package path を毎回指定しない。`a2o kanban ...` と `a2o agent install` は、カレントディレクトリから上方向に instance config を探索して、対象 package と runtime instance を解決する。runtime instance の compose project name を branch namespace として注入するため、isolated board で同じ `Portal#1` が作られても既存 live repo の historical `a3/work/Portal-1` branch を再利用しない。

## 利用者が用意するもの

利用者が用意するのは project package である。A2O core validation では `reference-products/multi-repo-fixture/project-package` を標準サンプルとして扱う。

project package は次を持つ。

- `project.yaml` または `project.json`: project 名、kanban project、repo slot、phase、trigger label、agent environment を定義する。
- `kanban/bootstrap.json`: kanban board / lane / tag 初期化設定を定義する。
- `hooks/`: project 固有の verification / remediation / bootstrap hook を置く。
- `README.md`: project package の設定値と前提 toolchain を説明する。

A2O 利用者が作らないものは次である。

- A2O runtime 起動用の長い shell script。
- `execute-until-idle` の長い引数列。
- `a2o agent package export` の checksum / target 判定 glue。
- `a2o-agent` の workspace materializer 設定 script。
- kanban provider API を直接叩く wrapper。

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
  workspace_root: /Users/example/workspace/mypage-prototype/.work/a2o-agent/workspaces
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

`repos.*.path` と `agent.workspace_root` は agent から見た path である。A2O Engine container から見た path ではない。

## 初回セットアップ

A2O release 後の利用者コマンドは次の形にする。

```bash
mkdir -p "$HOME/.local/bin" "$HOME/.local/share"
docker run --rm \
  -v "$HOME/.local:/install" \
  ghcr.io/wamukat/a2o-engine:latest \
  a2o host install \
    --output-dir /install/bin \
    --share-dir /install/share/a2o \
    --runtime-image ghcr.io/wamukat/a2o-engine:latest
export PATH="$HOME/.local/bin:$PATH"

a2o project bootstrap --package ./a2o-project
a2o kanban up
a2o kanban doctor
a2o agent install --target auto --output ./.work/a2o-agent/bin/a2o-agent
```

`a2o host install` は Docker image に同梱された Go host launcher と A2O 配布 asset を host へコピーする。container 内の Ruby Engine CLI は host に出ない。host 側の `$HOME/.local/bin/a2o` は POSIX shell wrapper で、`uname` により `a2o-darwin-amd64` / `a2o-linux-amd64` などの platform binary を選んで実行する。互換 alias として `$HOME/.local/bin/a3` も同時に配置される。標準 compose file は `$HOME/.local/share/a2o` 配下へ配置される。Docker から export するため、`bin` だけではなく `$HOME/.local` のような install prefix を mount する。`--runtime-image` は後続の `a2o kanban ...` が起動する Engine image を記録する。

`a2o agent install` は Engine image に同梱された agent release binary を host または project dev-env へ export する。利用者向けの出力名は `a2o-agent` とする。利用者に Go toolchain や Ruby interpreter を要求しない。

## 日常実行

この slice の public surface では、利用者が通常触る kanban entrypoint は service lifecycle に限定する。

```bash
a2o kanban up
a2o kanban doctor
a2o kanban url
```

kanban task selection、agent job queue、artifact store 反映は A2O 内部の runtime flow が担当する。利用者は `execute-until-idle` の詳細引数を直接組み立てない。

## agent fallback / diagnostic 起動が必要な場合

通常の導入と接続確認は `a2o agent install` と `a2o kanban ...` で行う。direct `a2o-agent --loop` は標準導線ではなく、project dev-env residency、diagnostic、operator-controlled fallback が必要な場合だけ使う。

```bash
a2o-agent --engine http://localhost:7393 --loop --poll-interval 2s
```

この場合でも repo path、workspace root、required bins は agent local profile ではなく、Engine 側 project package から job payload として渡す。

## Reference Product での現状

現行 A2O core validation の標準対象は `reference-products/` の project package である。入口は `a2o project bootstrap` / `a2o kanban up` / `a2o kanban doctor` / `a2o agent install` であり、製品 workspace-local Taskfile は通常導線ではない。内部互換として `a3 ...` も動作する。

```bash
a2o project bootstrap --package ./reference-products/multi-repo-fixture/project-package
a2o kanban up
a2o kanban doctor
a2o kanban url
a2o agent install --target auto --output ./.work/a2o-agent/bin/a2o-agent
```

製品 workspace-local の Taskfile 互換入口は削除済みであり、利用者向け入口は `a2o project bootstrap` と `a2o kanban up` / `doctor` / `url` に限定する。

project package の `runtime/run_once.sh` は不要であり、利用者も project package も実行 shell script を持たない。

## 残タスク

- A2O Engine の execution loop は internal runtime flow として扱い、public kanban service surface へ不用意に露出しない。stale recovery / retention cleanup の cycle hook は後続 hardening として扱う。
- project package loader と runtime instance config は実装済みであり、`a2o project bootstrap --package ./a2o-project` 後は package 指定不要で `a2o kanban ...` / `a2o agent install` が instance config を探索する。今後も multi-project registry に見える `--project NAME` は標準入口にしない。
- `a2o agent install` は release artifact に含め、runtime image から host/dev-env への binary export を利用者向け配布物として固定済み。release 前には正式 image ref で同手順を再 smoke する。
- Portal runtime shell script の責務は Engine command へ移設済み。残りは Portal 固有値を project package config から読む範囲を広げ、hardcoded Portal default を減らすこと。
- `A3_RUNTIME_RUN_ONCE_*` のような内部 env は project package / CLI option に寄せ、利用者の主要入口から隠す。
- A2O runtime compose file は A2O 配布物として同梱し、project package 側に compose file 作成を要求しない。compose override は開発・診断用に限定する。
