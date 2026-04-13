# A3 Runtime Naming Boundary

対象読者: A3 設計者 / runtime 実装者 / Portal project tooling 保守者
文書種別: 用語境界メモ

この文書は、A3 の current public surface で使う `runtime` 用語と、内部互換として残る `scheduler` 用語の境界を定義する。

## 方針

- 利用者向けの入口名は `runtime run-once` / `runtime loop` に寄せる。
- `scheduler` は OS service 名ではなく、Engine-managed runtime loop の内部 cycle/state/store 名として扱う。
- root `task --list` に出る公開IFへ `scheduler` を再導入しない。
- 内部 class / command / storage 名の一括改名は、migration plan と state compatibility test が揃うまで行わない。

## 公開IFで使う名前

- `task a3:portal:runtime:run-once`
- `task a3:portal:runtime:watch-summary`
- `task a3:portal:runtime:describe-state`
- Docker 上の A3 runtime command
- Go release binary としての `a3-agent`
- Engine image 同梱 agent package: `a3 agent package list/export/verify`

公開ドキュメントでは、継続実行の概念を説明する場合も `runtime run loop` と呼ぶ。OS service 化は current release scope 外であり、`scheduler service` とは呼ばない。

完成形では A3 Engine container が runtime loop process を持ち、kanban selection / run state / agent job queue を管理する。`a3-agent` は scheduler を持たず、host/project-dev-env 上で job を poll/execution する worker である。

agent 環境用設定は Engine 側 project config に置く。ただし、その値は agent から見た path / URL として扱い、Engine container path として解釈しない。Engine は設定の schema と job payload 生成を担当し、実 path / toolchain の到達性確認は agent doctor job が担当する。

## 内部互換として残す名前

次は現時点で改名しない。

- Engine domain/application class: `SchedulerLoop`, `SchedulerCycle`, `SchedulerState`
- Engine CLI maintenance command: `show-scheduler-state`, `show-scheduler-history`, `pause-scheduler`, `resume-scheduler`, `migrate-scheduler-store`
- Storage / lock / migration artifact: `scheduler_journal.json`, `scheduler-shot.lock`, scheduler store migration marker
- Root-local hidden maintenance task: `a3:portal:scheduler:*`
- Compatibility env fallback: `A3_RUNTIME_SCHEDULER_*`
- Historical isolated validation task: `a3:portal-soloboard:scheduler:*`

これらは現在の persisted state と operator recovery に結びついているため、公開IF整理とは別スライスで扱う。

## 削除・改名対象

次は見つけ次第 `runtime` 用語へ寄せる。

- README / AGENTS / launcher guidance の「利用者が scheduler を起動する」ように読める説明
- `task --list` に出る `a3:portal:*scheduler*` の公開 task
- current run-once entrypoint を `runtime:scheduler:run-once` と呼ぶ記述
- OS service 化が current release scope に含まれるように読める記述

## Historical 記述の扱い

過去の A3-v2 / legacy scheduler / validation evidence を説明する文脈では、事実として `scheduler` を残してよい。ただし、current operator surface と混同しないよう、近傍で historical / maintenance-only / internal のいずれかを明示する。
