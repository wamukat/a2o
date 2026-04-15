# User Runtime Command Implementation Plan

対象読者: A3 設計者 / 実装者
文書種別: 実装計画

この文書は、[90-user-quickstart.md](90-user-quickstart.md) の利用者体験を実装するための段階計画である。目的は、利用者が project package を用意するだけで A2O を実行できるようにし、長い shell script や `execute-until-idle` の詳細引数を利用者から隠すことである。公開名称は A2O、内部実装名は A3 とする。境界は [92-a2o-public-branding-boundary.md](92-a2o-public-branding-boundary.md) を参照する。

## ゴール

利用者の通常操作を次に収束させる。

```bash
docker run --rm -v "$HOME/.local:/install" ghcr.io/<a2o-owner>/a2o-engine:latest a2o host install --output-dir /install/bin --share-dir /install/share/a2o --runtime-image ghcr.io/<a2o-owner>/a2o-engine:latest
a2o project bootstrap --package ./a2o-project
a2o runtime up
a2o agent install --target auto --output ./.work/a2o-agent/bin/a2o-agent
a2o runtime doctor
a2o runtime run-once
```

継続運用では次を使う。

```bash
a2o runtime loop
```

`task a3:portal:runtime:*` は Portal workspace-local の暫定入口であり、A2O release の利用者に作らせるものではない。

`--package` は `a2o project bootstrap` の入力であり、単一 project package の path を指す。bootstrap はカレント workspace に runtime instance config を作成する。bootstrap 後の `a2o runtime ...` と `a2o agent install` は、カレントディレクトリから上方向に instance config を探索して対象 package を解決するため、通常操作では package path を毎回指定しない。

現行完成形は「1 project package = 1 runtime instance」であり、1つの Engine instance に複数 project を登録して `--project NAME` で切り替える registry 型にはしない。複数 project を扱う場合は、project package ごとに compose project name / storage dir / port / workspace root を分けた別 runtime instance を起動する。

## 役割分担

- Host launcher `a2o`
  - Docker compose up/down/logs を扱う。
  - Engine image から `a2o-agent` binary を export/install する。
  - `runtime run-once` / `runtime loop` の operator entrypoint を提供する。
  - 利用者 host に Ruby を要求しない。Go single binary として配布する。
- Docker A2O Engine
  - kanban selection、run state、agent job queue、artifact store、runtime loop を管理する。
  - `execute-until-idle` の詳細引数を project package から組み立てる。
  - project command を直接実行しない。
- `a2o-agent`
  - host または project dev-env 上で job を pull して実行する。
  - workspace materialization、project command、merge、cleanup を agent 視点の path で実行する。
  - repo path / workspace root / required bins は Engine job payload から受け取る。
- Project package
  - kanban bootstrap、repo slot、agent environment、phase hook を定義する。
  - 実行 shell script ではなく設定である。
  - A2O/SoloBoard compose file を持たない。compose は A2O 配布物の一部であり、project package が持つのは bootstrap/config だけである。
- Runtime instance config
  - `a2o project bootstrap --package ./a2o-project` により workspace 内へ生成される。実ファイル path は内部互換のため `.a3/runtime-instance.json` のままとする。
  - package path、compose project name、storage dir、ports、agent workspace root など、1 runtime instance 固有値を保持する。
  - `a2o runtime ...` / `a2o agent install` はこの config を探索して読む。
  - global project registry ではない。

## 実装スライス

### Slice 0: host launcher extraction

Docker image から host launcher `a2o` を取り出せる入口を提供する。

- `[done]` container 内 Engine CLI に `a2o host install --output-dir DIR` を追加する。内部互換として `a3 host install` も残す。
- `[done]` Docker image に同梱される platform 別 Go launcher を output dir へ `a2o-<os>-<arch>` としてコピーする。内部互換として `a3-<os>-<arch>` も残す。
- `[done]` output dir の `a2o` は shell wrapper とし、host の `uname` で platform binary を選ぶ。内部互換として `a3` wrapper も残す。
- `[done]` A2O 配布 asset を `$HOME/.local/share/a2o` 相当へコピーし、標準 compose file を host launcher から解決可能にする。internal fallback として `share/a3` も探索する。
- `[done]` `--runtime-image` で後続 runtime command が使う Engine image ref を share asset として記録する。
- `[todo]` Docker Hub / GHCR の正式 image ref が決まったら quickstart の `<org>` placeholder を置換する。

container 内から host OS は判定できないため、単一 target を推測してコピーしない。全 platform launcher と host-side wrapper を配置することで、macOS / Linux / WSL2 Ubuntu を同一コマンドで扱う。

### Slice 1: command naming parity

利用者向け README に出てくる command と現行実装の差分を減らす。

- `a2o-agent --engine URL` を `--control-plane-url URL` の alias として受け付ける。
- `a2o-agent doctor --engine URL` も同じ alias を受け付ける。
- docs の agent 起動例を実装済み option と一致させる。

### Slice 2: host launcher skeleton

Go binary として host launcher `a2o` を追加する。

- `[done]` `a2o version`
- `[done]` `a2o agent target`
- `[done]` `a2o agent install --target auto --output PATH`
- `[done]` `a2o runtime command-plan`

この時点では `run-once` をまだ実行しなくてよい。まず利用者に見せる command surface と引数 parse を固定する。`a2o agent install` は Docker A2O Engine runtime image を起動し、runtime container 内の agent package を verify/export して host path へ配置する。local source から確認する場合は `--build` で runtime image を明示再ビルドし、古い image から古い agent を取り出す事故を避ける。標準 compose は A2O 配布物として解決し、通常利用者に `--compose-file` を指定させない。

### Slice 3: project package loader

Portal 固有値を `scripts/a3-projects/portal/runtime/run_once.sh` から project package config と runtime instance config へ移す。loader は bootstrap 済み runtime instance config から単一 package path を読み込む。project name registry や global project catalog は持たない。

- `[done]` bootstrap 済み workspace に `.a3/runtime-instance.json` を作成する。
- `[done]` `a2o runtime up` / `doctor` / `down` / `command-plan` は bootstrap 済み runtime instance config を読む。
- `[done]` `a2o agent install` は bootstrap 済み runtime instance config から compose file / compose project / runtime service を読む。
- `[todo]` compose file / project name / ports / storage dir
- `[todo]` SoloBoard URL / internal URL
- `[todo]` manifest path
- `[todo]` live ref
- `[todo]` repo source path
- `[todo]` agent workspace root
- `[todo]` required bins
- `[todo]` worker command / worker args

loader は fail-fast とし、未設定時に暗黙 fallback で Portal 固有値を補わない。

### Slice 4: generic runtime run-once

host launcher `a2o runtime run-once` が次を実行する。

- `[done]` 利用者入口として `a2o runtime run-once` を追加する。
- `[done]` bootstrap 済み runtime instance config から package / compose file / compose project / ports / workspace root を注入する。
- `[done]` project package の `runtime/run_once.sh` 呼び出しを削除し、Go host launcher 内の generic runtime command で直接実行する。
- `[done]` runtime instance の compose project name を `A3_BRANCH_NAMESPACE` として注入し、`refs/heads/a3/<namespace>/work/...` / `parent/...` を使う。
- `[done]` compose up
- `[done]` stale runtime process cleanup
- `[done]` Engine image から `a2o-agent` export/install
- `[done]` Engine container 内の internal `a3 agent-server` 起動
- `[done]` Engine container 内の internal `a3 execute-until-idle` 起動
- `[done]` host `a2o-agent` single-job loop
- `[done]` runtime log / agent log / exit code の集約

`scripts/a3-projects/portal/runtime/run_once.sh` は削除済み。root Taskfile の互換入口は `go run ./a3-engine/agent-go/cmd/a3 runtime run-once` を呼ぶ。

### Slice 5: runtime loop

`a2o runtime loop` を追加する。

- `[done]` run-once を interval 実行する host launcher command を追加する。
- `[done]` `--max-cycles` で release validation / operator test 用に有限 cycle 実行できるようにする。
- `[done]` `--max-steps` / `--agent-attempts` を各 run-once cycle へ渡す。
- `[todo]` active run / stale process / repairable state を cycle 前に検査する。
- `[todo]` disk/artifact retention を cycle 後に実行できるようにする。
- OS service 登録は標準 scope に入れない。必要なら利用者が外側で wrapper 化する。

### Slice 6: Portal wrapper retirement

Portal root Taskfile は最終的に次だけを呼ぶ。

```bash
a2o runtime run-once
```

Portal package に残すのは `inject/config`, `inject/hooks`, `maintenance` のみとし、runtime shell script は戻さない。

### Slice 7: release readiness closeout

機能完成後の release candidate 化に向けて、次を完了条件として扱う。

- `[done]` A2O Engine runtime image を再ビルドし、Engine image 同梱の host launcher / agent package を使って Portal isolated runtime を起動する。
- `[done]` Portal 実チケットの parent-child flow で、child implementation -> child verification -> child-to-parent merge -> parent review -> parent verification -> live repo merge まで完走する。
- `[done]` `repo:starters` parent-child validation で live repo `member-portal-starters feature/prototype` が child commit `c8a90bd0` へ進むことを確認する。
- `[done]` implementation worker が宣言した `changed_files` と実 worktree 差分がずれた場合でも、edit-target の実差分を publish できるようにする。
- `[done]` Portal launcher の Codex model 設定を current ChatGPT account で利用可能な model に更新する。
- `[done]` `a2o runtime loop` の host launcher command を実装し、有限 cycle validation を可能にする。
- `[todo]` GHCR の正式 image ref を決め、`90-user-quickstart.md` と本計画の `<a2o-owner>` placeholder を置換する。
- `[done]` local release image equivalent (`a3-portal-bundle-a3-runtime`) で `a2o host install` -> `a2o project bootstrap` -> `a2o runtime up` -> `a2o agent install` -> `a2o runtime doctor` -> `a2o runtime command-plan` の smoke を実行する。public launcher `a2o`、compat alias `a3`、public share dir `share/a2o`、public agent path `.work/a2o-agent/bin/a2o-agent` を確認済み。
- `[todo]` 正式 registry image ref 公開後に、同じ smoke を registry image で再実行する。
- `[todo]` Portal live repo を remote 最新へ整理し直す場合の再適用手順を確認する。A3 実行に必要な Taskfile / injected project package / repo-local bootstrap 変更は、remote 最新化後に意図的に再投入する。
- `[todo]` validation 用 ticket / branch / workspace / Docker runtime を release 前 cleanup 手順として再点検する。

## 完了条件

- 利用者向け README の command が実装と一致している。
- 利用者が `operator-tests` や project-local runtime shell script の中身を読まなくても A2O を起動できる。
- Portal 固有値は project package にあり、A2O Engine core には Portal 固有 path / tag / port が焼き込まれていない。
- `a2o-agent` は `--engine` だけで control plane URL を受け取れる。
- `task a3:portal:runtime:run-once` は thin wrapper または削除済みであり、長い実行ロジックを保持しない。
