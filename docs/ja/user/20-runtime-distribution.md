# Container Distribution And Project Runtime（container 配布と project runtime）

対象読者: A2O 利用者 / runtime 実装者 / operator
文書種別: 配布設計 / runtime 境界

A2O の配布単位は Docker runtime image、host launcher、project package、`a2o-agent` である。利用者は Engine 内部の長い command line や runtime shell script を作らない。

## 配布物

- Runtime image: Engine CLI、compose asset、host install asset、agent release binary を含む。
- Host launcher: `a2o`。host から runtime image を操作する薄い Go binary である。
- Agent: `a2o-agent`。host または project dev-env で job を pull し、project command を実行する。
- Project package: project 名、kanban bootstrap、repo slot、runtime parameter、agent requirement、task template を宣言する。

内部互換のため、runtime image 内には `a3` CLI と `.a3` state path が残る。利用者向け surface では `a2o` と `a2o-agent` を使う。

runtime image 内の `a2o --help` は container entrypoint の help であり、host launcher の完全な help ではない。`a2o project template`、`a2o project bootstrap`、`a2o kanban ...`、`a2o runtime ...` などの通常操作は、`a2o host install` で取り出した host launcher の `a2o` から実行する。

## Runtime の形

A2O は「1 project package = 1 runtime instance」として扱う。

bootstrap は project package から runtime instance config を作成する。以後の `a2o kanban ...` と `a2o agent install` はカレントディレクトリから instance config を探索し、対象 package、storage、compose project、runtime image を解決する。

```sh
a2o project bootstrap
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
a2o kanban up
a2o runtime watch-summary
a2o runtime run-once
```

`./project-package` または `./a2o-project` 以外に package を置く場合は `a2o project bootstrap --package DIR` を使う。

`a2o runtime up` / `down` は runtime container lifecycle だけを扱い、scheduler を開始しない。task processing を常駐実行する場合だけ `a2o runtime start` を使う。

複数 product を同時に動かす場合は、package ごとに workspace、storage dir、compose project name、port を分ける。

## 責務境界

A2O Engine が持つもの:

- kanban service lifecycle
- task polling and transition
- workspace and branch namespace management
- worker gateway and agent job queue
- verification and merge phase orchestration
- evidence retention

Project package が持つもの:

- project name and kanban board name
- repo slot aliases and source paths
- trigger labels and task templates
- verification/build/test commands
- required toolchain names for agent-side execution
- declarative command では不足する場合の project-specific hook scripts

Project package が持たないもの:

- Engine runtime loop script
- A2O core services 用 Docker compose file
- kanban provider API wrapper
- agent materializer configuration script
- release asset export logic

## Release 0.5.0 の公開 surface

A2O 0.5.0 は、local-first runtime image、host launcher、agent package として配布する。標準 validation surface は reference product suite である。SoloBoard pickup and transitions、agent-materialized workspaces、agent HTTP worker gateway、verification、merge、parent-child flow、watch summary、describe-task diagnostics、evidence persistence を確認する。

Public launcher は host install、project bootstrap、kanban service lifecycle、kanban diagnosis、URL discovery、agent install、runtime container up/down、one-shot runtime execution、foreground runtime loop、resident scheduler start/stop/status、runtime diagnosis、multi-task watch summary、task/run observability を扱う。

## Operator notes（運用 notes）

- Project toolchain は runtime image に入れない。`a2o-agent` が動く host または dev-env に install する。
- 小さい task number を複数 isolated boards で再利用しても existing refs と衝突しないよう、branch namespace は instance-specific に保つ。
- `.work/a2o/` は disposable runtime output として扱う。new bootstrap state、host-agent binaries、generated launcher config、agent workspaces はそこに置く。
- 既存の `.a3/runtime-instance.json` は compatibility fallback としてだけ読む。新しい bootstrap は書き出さない。
- materialized repo workspaces 内の `.a3/` directories は internal agent metadata であり、user-managed package files ではない。
- 新しい Engine hardcoded defaults より、project package declarations を優先する。
