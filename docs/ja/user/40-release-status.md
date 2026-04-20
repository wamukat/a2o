# A2O 0.5.3 Release Status（release 状態）

## Ready（利用可能）

- Host launcher install（host launcher の install）: `a2o host install`
- Project bootstrap: `a2o project bootstrap`、任意で `--package DIR`
- Kanban service lifecycle（kanban service の起動・診断）: `a2o kanban up`、`doctor`、`url`
- Agent binary export（agent binary の書き出し）: `a2o agent install`
- Runtime container lifecycle（runtime container の起動・停止）: `a2o runtime up`、`down`
- Foreground runtime execution（foreground 実行）: `a2o runtime run-once`、`a2o runtime loop`
- Resident scheduler lifecycle（常駐 scheduler lifecycle）: `a2o runtime start`、`stop`、`status`
- Runtime diagnosis（runtime 診断）: `a2o runtime doctor`、`a2o runtime watch-summary`、`a2o runtime describe-task <task-ref>`
- Upgrade diagnosis（upgrade 診断）: `a2o upgrade check`
- Single-file project package config（単一ファイル project package config）: `project.yaml`
- SoloBoard adapter and bootstrap tooling。既定 SoloBoard image は `v0.9.15`
- Agent HTTP worker gateway
- Agent-materialized workspace mode
- TypeScript、Go、Python、multi-repo task templates の reference product packages
- main push 時の GHCR image publication。tags は `latest`、`0.5.3`、`sha-*`
- Full RSpec release gate の local pass

## Validation scope（検証範囲）

Release validation は reference product suite を使い、single-repo と multi-repo の task flow を kanban、agent gateway、verification、merge、parent-child handling、runtime watch summary、describe-task diagnostics、evidence persistence まで通して確認する。

## Productization gaps（productization 上の gap）

Productization gaps は、実装前に A2O kanban で tracking する。外部 behavior の変更が必要な場合は、coding 前に owner と協議する。
