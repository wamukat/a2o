# Container Distribution And Project Runtime

対象読者: A2O 利用者 / runtime 実装者 / operator
文書種別: 配布設計 / runtime 境界

A2O の配布単位は Docker runtime image、host launcher、project package、`a2o-agent` である。利用者は Engine 内部の長い command line や runtime shell script を作らない。

## 配布物

- Runtime image: Engine CLI、compose asset、host install asset、agent release binary を含む。
- Host launcher: `a2o`。host から runtime image を操作する薄い Go binary である。
- Agent: `a2o-agent`。host または project dev-env で job を pull し、project command を実行する。
- Project package: project 名、kanban bootstrap、repo slot、runtime parameter、agent requirement、scenario を宣言する。

内部互換のため、runtime image 内には `a3` CLI と `.a3` state path が残る。利用者向け surface では `a2o` と `a2o-agent` を使う。

## Runtime Shape

A2O は「1 project package = 1 runtime instance」として扱う。

bootstrap は project package から runtime instance config を作成する。以後の `a2o kanban ...` と `a2o agent install` はカレントディレクトリから instance config を探索し、対象 package、storage、compose project、runtime image を解決する。

```sh
a2o project bootstrap --package ./reference-products/typescript-api-web/project-package
a2o kanban up
a2o kanban doctor
a2o kanban url
a2o agent install --target auto --output ./.work/a2o-agent/bin/a2o-agent
a2o runtime run-once
```

複数 product を同時に動かす場合は、package ごとに workspace、storage dir、compose project name、port を分ける。

## Responsibility Boundary

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
- trigger labels and scenario task templates
- verification/build/test commands
- required toolchain names for agent-side execution
- project-specific hook scripts when a declarative command is insufficient

Project package が持たないもの:

- Engine runtime loop script
- Docker compose file for A2O core services
- kanban provider API wrapper
- agent materializer configuration script
- release asset export logic

## Current Release Gate

The current baseline exercises the reference product suite through SoloBoard, agent-materialized workspaces, agent-http worker gateway, verification, merge, and evidence persistence. The recorded baseline is [69-reference-runtime-baseline.md](69-reference-runtime-baseline.md).

The public launcher covers host install, project bootstrap, kanban service lifecycle, kanban diagnosis, URL discovery, agent install, one-shot runtime execution, foreground runtime loop, and runtime diagnosis. Resident scheduler start/stop/status is tracked separately as release hardening.

## Operator Notes

- Keep project toolchains out of the runtime image. Install them in the host or dev-env where `a2o-agent` runs.
- Keep branch namespaces instance-specific so isolated boards can reuse small task numbers without colliding with existing refs.
- Treat `.work/` as disposable runtime output and `.a3/` as internal runtime state.
- Prefer project package declarations over new Engine hardcoded defaults.
