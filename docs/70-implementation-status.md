# A3 Engine Implementation Status

## 目的

このドキュメントは、A3 Engine で実装すべき機能の全体像と、各機能の現在の完成状態をチェックリストで管理するためのものです。
current `a3-v2` を future `a3-engine` base として seed するため、`a3-engine/docs/IMPLEMENTATION_STATUS.md` を取り込んだ current copy として扱う。

- 設計方針の正本: `docs/75-engine-redesign.md`
- cutover / naming plan の正本: `docs/80-a3engine-reseed-and-naming-cutover-plan.md`
- current runtime / operator surface の正本: `docs/60-container-distribution-and-project-runtime.md`
- 実装進捗の正本: このファイル

## 読み方

- この文書は reseed 前の `a3-engine` 実装証跡を future base 側へ持ち込むための seeded status である
- `a3_engine/*` や `scripts/a3/run.py` などの Python path / command は、cutover 前の implementation provenance を保持するために残している
- current operator entrypoint や live runtime の正本は `docs/60-container-distribution-and-project-runtime.md` と root の `task a3:*` / `scripts/a3/*.rb` を参照する
- cutover 実行 slice が進んだら、この文書中の evidence も新 `/a3-engine` surface に合わせて更新する

## ステータスの見方

- `- [x]`: 基本機能が実装済みで、回帰 test または実運用相当の確認がある
- `- [ ]`: 未完了。未着手と進行中の両方を含む

補足が必要な項目は、直下に「現状」「残課題」を短く書く。

## Core

- [x] project manifest schema / validation
  現状: 外部 JSON manifest の load / validate / normalize が可能。
  根拠: `a3_engine/manifest.py`, `tests/test_manifest.py`

- [x] repo selection / trigger resolution
  現状: label route と `team_plan.repos` から対象 repo を解決できる。
  根拠: `a3_engine/runtime.py`, `a3_engine/cli.py`

- [x] runtime context / phase planning
  現状: `describe-context` / `plan-run` / `describe-phase-plan` が動く。
  根拠: `a3_engine/runtime.py`, `a3_engine/runner.py`

- [x] semantic verification intent
  現状: manifest 上の intent を repo-local command に解決できる。

- [x] preflight guard evaluation
  現状: read-only guard 評価と structured output がある。
  根拠: `a3_engine/preflight.py`, `tests/test_preflight.py`

- [x] phase executor
  現状: preflight 通過後に verification command を順次実行できる。
  根拠: `a3_engine/phase_executor.py`, `tests/test_phase_executor.py`

- [x] branch contract materialization
  現状: engine が `source_workspace` / `runtime_workspace` を resolved binding として materialize し、preflight / phase executor が `execution_path` を消費する。`work_branch_ref` / `integration_branch_ref` を読める受け皿はあるが、Portal live runtime で child work branch と parent integration branch を実際に分離して走らせる段階までは未完了。
  根拠: `a3_engine/runtime.py`, `a3_engine/preflight.py`, `a3_engine/phase_executor.py`

- [x] merge/apply executor
  現状: trigger 別 merge policy を使って isolated repo 上の fast-forward merge を実行できる。
  根拠: `a3_engine/merge_executor.py`, `tests/test_merge_executor.py`

- [x] parent integration judgment contract
  現状: parent finalize / merge は structured integration judgment を前提にし、script-only finalize path を正規経路としない。
  根拠: `a3_engine/run_once_executor.py`, `a3_engine/worker_executor.py`, `tests/test_run_once_executor.py`, `tests/test_worker_executor.py`

- [x] active-run persistence
  現状: active-run refs を file-backed store に load/save でき、selection / dry-run mutation planning が persisted active refs を消費できる。
  根拠: `a3_engine/active_run_store.py`, `a3_engine/runner.py`, `tests/test_active_run_store.py`, `tests/test_orchestration.py`

- [x] blocked recovery / kanban orchestration
  現状: kanban read/write adapter、task snapshot planner、active-run selection、active-run persistence、real kanban mutation adapter が揃い、snapshot load -> selection -> mutation apply を end-to-end 化できた。`commit-preserving workspace refresh failed` は `blocked_refresh_failure` / `Backlog` に自動正規化され、lane unclogging を operator の手作業に依存しない。
  根拠: `a3_engine/orchestration.py`, `a3_engine/active_run_store.py`, `a3_engine/kanban_adapter.py`, `tests/test_orchestration.py`, `tests/test_active_run_store.py`, `tests/test_kanban_adapter.py`

- [x] kanban task snapshot acquisition
  現状: real kanban adapter から `task-list` / `task-get` / `task-label-list` を読み、scheduler 用 `TaskSnapshot` を構築できる。
  根拠: `a3_engine/kanban_adapter.py`, `a3_engine/launcher.py`, `tests/test_kanban_adapter.py`

- [x] worker prompt handoff / structured result persistence
  現状: implementation の `worker-execution` action を ai-cli executor へ渡し、per-run result bundle を `.work/a3/results/...` へ保存できる。review worker payload は次段の slice で扱う。
  根拠: `a3_engine/worker_executor.py`, `tests/test_worker_executor.py`

- [x] integrated run-once execution
  現状: `plan-run-once -> execute-worker-action -> apply-worker-result` を 1 本の `execute-run-once` で実行できる。
  根拠: `a3_engine/run_once_executor.py`, `tests/test_run_once_executor.py`

- [x] review-phase integrated run-once routing
  現状: `In review` の worker action も integrated run-once で処理でき、review worker の structured result から `comment + desired_status` を kanban mutation へ反映できる。
  根拠: `a3_engine/worker_executor.py`, `a3_engine/worker_result_handler.py`, `a3_engine/run_once_executor.py`, `tests/test_worker_executor.py`, `tests/test_worker_result_handler.py`, `tests/test_run_once_executor.py`

- [x] watch loop / Portal live cutover integration
  現状: `portal` live launcher config は `execute-run-once` を呼ぶ launchd package を持ち、root から manual run と launchd install / uninstall / reload / status を操作できる。launchd helper は macOS 専用で、非 macOS では fail-fast する。
  根拠: `scripts/a3/config/portal/launcher.json`, root `Taskfile.yml`, `scripts/a3/launchd.py`, `scripts/a3/tests/test_launchd.py`, `scripts/a3/tests/test_run.py`

## Runtime / Launcher

- [x] launcher config schema
  現状: project manifest と machine-local config を分離済み。
  根拠: `a3_engine/launcher_config.py`, `tests/test_launcher.py`

- [x] shell/env policy
  現状: shell, env files, overrides, inherit policy を扱える。
  根拠: `a3_engine/runtime_env.py`

- [x] executor adapter abstraction
  現状: `ai-cli` naming と implementation-specific detail を分離済み。
  根拠: `a3_engine/executor.py`

- [x] scheduler adapter abstraction
  現状: scheduler descriptor / launcher plan はある。
  根拠: `a3_engine/scheduler.py`, `a3_engine/launcher.py`

- [x] real scheduler packaging
  現状: launchd / cron / systemd-timer backend について、launcher config から deterministic な packaging artifact を describe/materialize できる。
  根拠: `a3_engine/scheduler_packaging.py`, `tests/test_scheduler_packaging.py`, `scripts/a3/run.py`

## Next Design Slice

- [ ] single / child 向け phase redesign slice
  現状: fresh な `single` / `child` は `implementation completed -> verification` へ進み、kanban status も `Inspection` へ遷移する。implementation worker は optional `review_disposition(kind=completed)` を返せるようになり、self-review clean の evidence は implementation run record と operator view に保持できる。あわせて `single` / `child` では `review` を canonical support phase から外し、Kanban 由来の `In review` も child/single では `Inspection` 相当へ正規化するようにした。watch-summary は canonical 4 phase を維持しつつ、current runtime / CLI / manual worker flow / operator read model から child review 前提は撤去済みである。残りは current 3-phase child flow を実 canary で継続確認しつつ、backend adapter 差し替え時に phase rule が backend 固有都合で汚染されないことを検証すること。
  根拠: `docs/60-container-distribution-and-project-runtime.md` の `0.4.5.2` と `0.4.5.3`

- [ ] SoloBoard bundled kanban and agent runtime packaging
  現状: SoloBoard は `comments`, `relations`, `transition`, `ref` / `shortRef` を含む API を公開しており、A3 Engine が現在使う kanban compatibility surface を adapter 経由で受け止められる。local Docker spike では `http://127.0.0.1:3460` で board / lane / tag / ticket / relation / comment / transition / list 系 API の疎通を確認済みで、workspace root では `task soloboard:doctor`, `task soloboard:api`, `task soloboard:bootstrap`, `task soloboard:smoke` と generic `task kanban:*` / `task kanban:smoke` の既定 backend を SoloBoard に寄せた。さらに `task a3:portal-soloboard:*` の isolated storage surface で single full-phase canary (`Portal#17`) と parent-child canary (`Portal#18/#19/#20`) を current live storage と分離して `Done` まで確認済みである。加えて local bundle spike として `task a3:portal:bundle:up`, `:doctor`, `:bootstrap`, `:smoke`, `:watch-summary`, `:describe-state`, `:run-once` を追加し、A3 runtime container + SoloBoard container の compose 入口と runtime container 内 implementation canary まで実機確認した。ただしこの spike は Portal verification のために A3 runtime image へ Temurin 25 JDK を入れており、完成形ではない。完成形では `docker:a3` は汎用 control plane、`docker:soloboard` は bundled kanban、project command 実行は host または project dev-env container に配置した `a3-agent` が担当する。
  残課題:
  - current A3 がまだ使っていない command surface を parity 確認する
  - repeated scheduler-loop と長時間運用で read-after-write 揺れが追加 hardening を要しないか確認する
  - Kanboard compatibility path を撤去または historical path に下げる判断を完了する
  - A3 image から project 固有 JDK / Maven / verification runtime を剥がす
  - `a3-agent` の JobRequest / JobResult / lifecycle / policy / transport を実装可能な粒度で固定する
  - Go single binary agent の scaffold と installer 方針を固定する
  - Docker compose bundle を `docker:a3` + `docker:soloboard` + optional `docker:dev-env(a3-agent)` の形へ更新する
  - bundle smoke と Portal full verification の完了条件を分離し、full verification は `a3-agent` 経由で再実行する
  根拠: `docs/60-container-distribution-and-project-runtime.md` の `0.4.5.1` と `0.4.5.1b`

## Portal Dev 実運用トラック

- [x] isolated repo bootstrap
  現状: source repo の current `HEAD` を isolated local `main` に materialize できる。
  根拠: `scripts/a3/bootstrap_portal_dev_repos.py`, `scripts/a3/tests/test_bootstrap_portal_dev_repos.py`

- [x] source `HEAD` materialization
  現状: source repo の current `HEAD` を isolated local `main` に配置できる。

- [x] detached `HEAD` refresh
  現状: detached source `HEAD` を explicit fetch して materialize 可能。

- [x] prerequisite command-surface guard
  現状: `Taskfile.yml` / `mvnw` / `pom.xml` 欠落を preflight で止められる。
  根拠: `scripts/a3/config/portal-dev/project.json`, `a3_engine/preflight.py`

- [x] implementation execution
  現状: `repo:ui-app` implementation を isolated repo 上で end-to-end 実行確認済み。
  根拠: `python3 scripts/a3/run.py execute-phase --project portal-dev --phase implementation --labels trigger:auto-implement,repo:ui-app`

- [x] child inspection execution
  現状: `repo:ui-app` child inspection を isolated repo 上で end-to-end 実行確認済み。
  根拠: `python3 scripts/a3/run.py execute-phase --project portal-dev --phase inspection --labels trigger:auto-implement,repo:ui-app`

- [x] parent inspection execution
  現状: `repo:ui-app` parent inspection を isolated repo 上で end-to-end 実行確認済み。
  根拠: `python3 scripts/a3/run.py execute-phase --project portal-dev --phase inspection --labels trigger:auto-parent,repo:ui-app`

- [ ] parent/child branch topology
  現状: `portal-dev` bootstrap では `a3/issue` / `a3/parent` を materialize できるが、Portal live runtime / canary では child `work_branch_ref` と parent `integration_branch_ref` の分離がまだ全面適用されていない。
  残課題:
  - Portal live manifest / launcher で new child + new parent を distinct branch refs で materialize する
  - child implementation / verification を shared issue branch ではなく child work branch に閉じる
  - live Portal parent-child canary で separated branch model を完走させる
  根拠: `scripts/a3/bootstrap_portal_dev_repos.py`, `scripts/a3/config/portal-dev/project.json`

- [x] merge execution
  現状: `repo:ui-app` の child merge / parent merge を isolated repo 上で end-to-end 実行確認済み。
  根拠: `python3 scripts/a3/run.py execute-phase --project portal-dev --phase merge --labels trigger:auto-implement,repo:ui-app`, `python3 scripts/a3/run.py execute-phase --project portal-dev --phase merge --labels trigger:auto-parent,repo:ui-app`

- [x] live repo handoff / promotion
  現状: merge 結果を launcher-config 管理の disposable live target へ dry-run / apply でき、canonical branch / clean-worktree guard を通す。
  根拠: `a3_engine/promotion_executor.py`, `tests/test_promotion_executor.py`, `scripts/a3/config/portal-dev/launcher.json`

## Root Integration

- [x] root launcher
  現状: root から manifest / launcher config を注入して A3 CLI を呼べる。
  根拠: `scripts/a3/run.py`

- [x] root task entrypoints
  現状: `task a3:portal-dev:*` 入口を持つ。
  根拠: root `Taskfile.yml`

- [x] root docs/skills migration
  現状: root `README.md` / `AGENTS.md` / legacy automation skills を A3 前提の責務分担へ追従済み。
  根拠: root `README.md`, root `AGENTS.md`, `.agents/skills/automation-*.md`

## 直近の優先実装順

- [x] additional scheduler backends を adapter 実装へ広げる
- [x] root docs/skills migration を実運用フローに追従させる
- [x] active-run persistence を local store と CLI に接続する
- [x] blocked recovery / kanban orchestration の real kanban mutation adapter を実装する
- [x] kanban task snapshot acquisition を real kanban adapter に接続する
- [x] recovery prerequisite / sidecar task category を scheduling policy に取り込む
  現状: manifest の `recovery_sidecar_labels` から run planning が `normal / recovery-sidecar` を区別できる。
- [x] watch loop / Portal live cutover integration を実装する
- [x] review-phase integrated run-once routing を実装する

## 完成判定の目安

- [x] project manifest だけで implementation / inspection / merge の phase contract を表現できる
- [x] root launcher から manifest と launcher config を注入して一連の phase を起動できる
- [ ] parent/child flow の branch contract が engine 実装に反映されている
  現状: 実運用で separated branch model は未導入。設計方針は `docs/issue-workspace-worktree-migration-design.md` を正本とする。
  残課題:
  - authoritative branch ownership の抽出
  - workspace backend abstraction の導入
  - runtime workspace の detached source 化
  - merge phase の branch-diff / integration-commit contract 明確化
- [x] merge preflight と merge/apply が engine 内で扱える
- [x] isolated repo から live repo への handoff が safety guard 付きで定義・実装されている
- [x] shell/env/scheduler 差を launcher config と adapter で吸収できる

このセクションがすべて `- [x]` になったら、Portal 実運用トラックは一通り成立したと見なせる。
