# User Runtime Command Implementation Plan

対象読者: A3 設計者 / 実装者
文書種別: 実装計画

この文書は、[90-user-quickstart.md](90-user-quickstart.md) の利用者体験を実装するための段階計画である。目的は、利用者が project package を用意するだけで A3 を実行できるようにし、長い shell script や `execute-until-idle` の詳細引数を利用者から隠すことである。

## ゴール

利用者の通常操作を次に収束させる。

```bash
a3 project bootstrap --package ./a3-project
a3 runtime up --project portal
a3 agent install --project portal --target auto --output ./.work/a3-agent/bin/a3-agent
a3 runtime doctor --project portal
a3 runtime run-once --project portal
```

継続運用では次を使う。

```bash
a3 runtime loop --project portal
```

`task a3:portal:runtime:*` は Portal workspace-local の暫定入口であり、A3 release の利用者に作らせるものではない。

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

## 実装スライス

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
- `[todo]` `a3 runtime command-plan --project PACKAGE_OR_NAME`

この時点では `run-once` をまだ実行しなくてよい。まず利用者に見せる command surface と引数 parse を固定する。`a3 agent install` は Docker A3 Engine runtime image を起動し、runtime container 内の agent package を verify/export して host path へ配置する。local source から確認する場合は `--build` で runtime image を明示再ビルドし、古い image から古い agent を取り出す事故を避ける。

### Slice 3: project package loader

Portal 固有値を `scripts/a3-projects/portal/runtime/run_once.sh` から project package config へ移す。

- compose file / project name / ports / storage dir
- SoloBoard URL / internal URL
- manifest path
- live ref
- repo source path
- agent workspace root
- required bins
- worker command / worker args

loader は fail-fast とし、未設定時に暗黙 fallback で Portal 固有値を補わない。

### Slice 4: generic runtime run-once

host launcher `a3 runtime run-once --project portal` が次を実行する。

- compose up
- stale runtime process cleanup
- Engine image から `a3-agent` export/install
- Engine container 内 `a3 agent-server` 起動
- Engine container 内 `a3 execute-until-idle` 起動
- host `a3-agent` single-job loop
- runtime log / agent log / exit code の集約

`scripts/a3-projects/portal/runtime/run_once.sh` は、この command を呼ぶ thin compatibility wrapper にする。

### Slice 5: runtime loop

`a3 runtime loop --project portal` を追加する。

- run-once を interval 実行する。
- active run / stale process / repairable state を cycle 前に検査する。
- disk/artifact retention を cycle 後に実行できるようにする。
- OS service 登録は標準 scope に入れない。必要なら利用者が外側で wrapper 化する。

### Slice 6: Portal wrapper retirement

Portal root Taskfile は最終的に次だけを呼ぶ。

```bash
a3 runtime run-once --project portal
```

`scripts/a3-projects/portal/runtime/run_once.sh` は、互換期間後に削除する。Portal package に残すのは `inject/config`, `inject/hooks`, `maintenance` のみとする。

## 完了条件

- 利用者向け README の command が実装と一致している。
- 利用者が `operator-tests` / `runtime/run_once.sh` の中身を読まなくても A3 を起動できる。
- Portal 固有値は project package にあり、A3 Engine core には Portal 固有 path / tag / port が焼き込まれていない。
- `a3-agent` は `--engine` だけで control plane URL を受け取れる。
- `task a3:portal:runtime:run-once` は thin wrapper または削除済みであり、長い実行ロジックを保持しない。
