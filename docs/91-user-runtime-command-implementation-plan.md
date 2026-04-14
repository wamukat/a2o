# User Runtime Command Implementation Plan

対象読者: A3 設計者 / 実装者
文書種別: 実装計画

この文書は、[90-user-quickstart.md](90-user-quickstart.md) の利用者体験を実装するための段階計画である。目的は、利用者が project package を用意するだけで A3 を実行できるようにし、長い shell script や `execute-until-idle` の詳細引数を利用者から隠すことである。

## ゴール

利用者の通常操作を次に収束させる。

```bash
docker run --rm -v "$HOME/.local:/install" docker.io/<org>/a3-engine:latest a3 host install --output-dir /install/bin --share-dir /install/share/a3 --runtime-image docker.io/<org>/a3-engine:latest
a3 project bootstrap --package ./a3-project
a3 runtime up
a3 agent install --target auto --output ./.work/a3-agent/bin/a3-agent
a3 runtime doctor
a3 runtime run-once
```

継続運用では次を使う。

```bash
a3 runtime loop
```

`task a3:portal:runtime:*` は Portal workspace-local の暫定入口であり、A3 release の利用者に作らせるものではない。

`--package` は `a3 project bootstrap` の入力であり、単一 project package の path を指す。bootstrap はカレント workspace に runtime instance config を作成する。bootstrap 後の `a3 runtime ...` と `a3 agent install` は、カレントディレクトリから上方向に instance config を探索して対象 package を解決するため、通常操作では package path を毎回指定しない。

現行完成形は「1 project package = 1 runtime instance」であり、1つの Engine instance に複数 project を登録して `--project NAME` で切り替える registry 型にはしない。複数 project を扱う場合は、project package ごとに compose project name / storage dir / port / workspace root を分けた別 runtime instance を起動する。

## 役割分担

- Host launcher `a3`
  - Docker compose up/down/logs を扱う。
  - Engine image から `a3-agent` binary を export/install する。
  - `runtime run-once` / `runtime loop` の operator entrypoint を提供する。
  - 利用者 host に Ruby を要求しない。Go single binary として配布する。
- Docker A3 Engine
  - kanban selection、run state、agent job queue、artifact store、runtime loop を管理する。
  - `execute-until-idle` の詳細引数を project package から組み立てる。
  - project command を直接実行しない。
- `a3-agent`
  - host または project dev-env 上で job を pull して実行する。
  - workspace materialization、project command、merge、cleanup を agent 視点の path で実行する。
  - repo path / workspace root / required bins は Engine job payload から受け取る。
- Project package
  - kanban bootstrap、repo slot、agent environment、phase hook を定義する。
  - 実行 shell script ではなく設定である。
  - A3/SoloBoard compose file を持たない。compose は A3 配布物の一部であり、project package が持つのは bootstrap/config だけである。
- Runtime instance config
  - `a3 project bootstrap --package ./a3-project` により workspace 内へ生成される。
  - package path、compose project name、storage dir、ports、agent workspace root など、1 runtime instance 固有値を保持する。
  - `a3 runtime ...` / `a3 agent install` はこの config を探索して読む。
  - global project registry ではない。

## 実装スライス

### Slice 0: host launcher extraction

Docker image から host launcher `a3` を取り出せる入口を提供する。

- `[done]` container 内 Engine CLI に `a3 host install --output-dir DIR` を追加する。
- `[done]` Docker image に同梱される platform 別 Go launcher `a3` を output dir へ `a3-<os>-<arch>` としてコピーする。
- `[done]` output dir の `a3` は shell wrapper とし、host の `uname` で platform binary を選ぶ。
- `[done]` A3 配布 asset を `$HOME/.local/share/a3` 相当へコピーし、標準 compose file を host launcher から解決可能にする。
- `[done]` `--runtime-image` で後続 runtime command が使う Engine image ref を share asset として記録する。
- `[todo]` Docker Hub / GHCR の正式 image ref が決まったら quickstart の `<org>` placeholder を置換する。

container 内から host OS は判定できないため、単一 target を推測してコピーしない。全 platform launcher と host-side wrapper を配置することで、macOS / Linux / WSL2 Ubuntu を同一コマンドで扱う。

### Slice 1: command naming parity

利用者向け README に出てくる command と現行実装の差分を減らす。

- `a3-agent --engine URL` を `--control-plane-url URL` の alias として受け付ける。
- `a3-agent doctor --engine URL` も同じ alias を受け付ける。
- docs の agent 起動例を実装済み option と一致させる。

### Slice 2: host launcher skeleton

Go binary として host launcher `a3` を追加する。

- `[done]` `a3 version`
- `[done]` `a3 agent target`
- `[done]` `a3 agent install --target auto --output PATH`
- `[done]` `a3 runtime command-plan`

この時点では `run-once` をまだ実行しなくてよい。まず利用者に見せる command surface と引数 parse を固定する。`a3 agent install` は Docker A3 Engine runtime image を起動し、runtime container 内の agent package を verify/export して host path へ配置する。local source から確認する場合は `--build` で runtime image を明示再ビルドし、古い image から古い agent を取り出す事故を避ける。標準 compose は A3 配布物として解決し、通常利用者に `--compose-file` を指定させない。

### Slice 3: project package loader

Portal 固有値を `scripts/a3-projects/portal/runtime/run_once.sh` から project package config と runtime instance config へ移す。loader は bootstrap 済み runtime instance config から単一 package path を読み込む。project name registry や global project catalog は持たない。

- `[done]` bootstrap 済み workspace に `.a3/runtime-instance.json` を作成する。
- `[done]` `a3 runtime up` / `doctor` / `down` / `command-plan` は bootstrap 済み runtime instance config を読む。
- `[done]` `a3 agent install` は bootstrap 済み runtime instance config から compose file / compose project / runtime service を読む。
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

host launcher `a3 runtime run-once` が次を実行する。

- `[done]` 利用者入口として `a3 runtime run-once` を追加する。
- `[done]` bootstrap 済み runtime instance config から package / compose file / compose project / ports / workspace root を注入する。
- `[done]` 現時点では project package の `runtime/run_once.sh` を呼び出し、利用者から script 直接実行を隠す。
- `[done]` runtime instance の compose project name を `A3_BRANCH_NAMESPACE` として注入し、`refs/heads/a3/<namespace>/work/...` / `parent/...` を使う。
- `[todo]` compose up
- `[todo]` stale runtime process cleanup
- `[todo]` Engine image から `a3-agent` export/install
- `[todo]` Engine container 内 `a3 agent-server` 起動
- `[todo]` Engine container 内 `a3 execute-until-idle` 起動
- `[todo]` host `a3-agent` single-job loop
- `[todo]` runtime log / agent log / exit code の集約

`scripts/a3-projects/portal/runtime/run_once.sh` は、この command を呼ぶ thin compatibility wrapper にする。

### Slice 5: runtime loop

`a3 runtime loop` を追加する。

- run-once を interval 実行する。
- active run / stale process / repairable state を cycle 前に検査する。
- disk/artifact retention を cycle 後に実行できるようにする。
- OS service 登録は標準 scope に入れない。必要なら利用者が外側で wrapper 化する。

### Slice 6: Portal wrapper retirement

Portal root Taskfile は最終的に次だけを呼ぶ。

```bash
a3 runtime run-once
```

`scripts/a3-projects/portal/runtime/run_once.sh` は、互換期間後に削除する。Portal package に残すのは `inject/config`, `inject/hooks`, `maintenance` のみとする。

## 完了条件

- 利用者向け README の command が実装と一致している。
- 利用者が `operator-tests` / `runtime/run_once.sh` の中身を読まなくても A3 を起動できる。
- Portal 固有値は project package にあり、A3 Engine core には Portal 固有 path / tag / port が焼き込まれていない。
- `a3-agent` は `--engine` だけで control plane URL を受け取れる。
- `task a3:portal:runtime:run-once` は thin wrapper または削除済みであり、長い実行ロジックを保持しない。
