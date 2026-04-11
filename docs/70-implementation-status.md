# A3 Engine Implementation Status

## 目的

このドキュメントは、A3 Engine で実装すべき機能の全体像と、各機能の現在の完成状態をチェックリストで管理するためのものです。
旧 `a3-v2` から current `a3-engine` へ seed 済みの implementation status を管理する。2026-04-11 時点で `a3-v2/` source tree と legacy automation scripts は削除済みであり、現行正本は `a3-engine` と root `scripts/a3` である。

- 設計方針の正本: `docs/75-engine-redesign.md`
- cutover / naming plan の正本: `docs/80-a3engine-reseed-and-naming-cutover-plan.md`
- current runtime / operator surface の正本: `docs/60-container-distribution-and-project-runtime.md`
- 実装進捗の正本: このファイル

## 読み方

- この文書は reseed 前の `a3-engine` 実装証跡を current base 側へ持ち込むための seeded status である
- `a3_engine/*` や `scripts/a3/run.py` などの Python path / command は、cutover 前の implementation provenance を保持するために残している
- current operator entrypoint や live runtime の正本は `docs/60-container-distribution-and-project-runtime.md` と root の `task a3:*` / `scripts/a3/*.rb` を参照する
- cutover 実行 slice は進行済みであり、この文書中の Python path / old command は provenance としてだけ残す。current operator surface は root `task a3:*` / `scripts/a3/*.rb` と `/a3-engine` 側 docs を参照する

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
  現状: SoloBoard は `comments`, `relations`, `transition`, `ref` / `shortRef` を含む API を公開しており、A3 Engine が現在使う kanban compatibility surface を adapter 経由で受け止められる。local Docker spike では `http://127.0.0.1:3460` で board / lane / tag / ticket / relation / comment / transition / list 系 API の疎通を確認済みで、workspace root では `task soloboard:doctor`, `task soloboard:api`, `task soloboard:bootstrap`, `task soloboard:smoke` と generic `task kanban:*` / `task kanban:smoke` の既定 backend を SoloBoard に寄せた。SoloBoard 起動は upstream GHCR image `ghcr.io/wamukat/soloboard:latest` を既定に切り替え済みで、local source checkout build には依存しない。さらに `task a3:portal-soloboard:*` の isolated storage surface で single full-phase canary (`Portal#17`) と parent-child canary (`Portal#18/#19/#20`) を current live storage と分離して `Done` まで確認済みである。加えて local bundle spike として `task a3:portal:bundle:up`, `:doctor`, `:bootstrap`, `:smoke`, `:watch-summary`, `:describe-state`, `:run-once` を追加し、A3 runtime container + SoloBoard container の compose 入口と runtime container 内 implementation canary まで実機確認した。ただし完成形では `docker:a3` は汎用 control plane、`docker:soloboard` は bundled kanban、project command 実行は host または project dev-env container に配置した `a3-agent` が担当する。現在は汎用 Go single-binary agent image (`docker/a3-agent`) と Portal dev-env agent image (`docker/a3-portal-agent`) を分離し、A3 runtime image へ project 固有 JDK / Maven / verification runtime を bake しない方向へ寄せた。Portal dev-env agent image には Java 25 / Ruby / Task / git / Python / Node/npm を入れ、`task a3:portal:bundle:agent-full-verification-smoke` で実 `member-portal-starters` repo、`task a3:portal:bundle:agent-ui-verification-smoke` で実 `member-portal-ui-app` repo の `task test:nullaway` まで agent-http 経由で確認済みである。
  2026-04-11 の実チケット smoke では、`Portal#37` が worker gateway 経由で `Inspection -> Done`、`Portal#39` が agent verification command runner 経由で `Merging -> Done`、`Portal#40` が child `Portal#41/#42` を集約する parent topology で `Done` まで到達した。`Portal#38` は synthetic non-Maven fixture に対する Maven bootstrap/prefetch が原因で blocked になったが、root commit `47dda1f` で non-Maven verification slot を skip するよう修正し、superseded canary として recovery comment / blocked label removal 後に `Done` 化した。
  さらに `ITERATIONS=6 INTERVAL_SECONDS=30 task a3:portal:bundle:observe` で bundle doctor / watch-summary / show-state / disk usage を約 3 分間反復観測し、全 iteration で active / queued / blocked が 0 の idle 状態を確認した。legacy direct `a3:portal:bundle:run-once` は docker:a3 内で project verification を実行しうるため、diagnostic canary `Portal#43` で失敗条件を確認したうえで明示 opt-in guard に下げ、通常検証は agent smoke 群に固定した。加えて `task a3:portal:bundle:agent-loop` を追加し、`Portal#44/#45/#46/#47/#48` の 1 周 smoke と、`Portal#49/#50/#51/#52/#53`、`Portal#54/#55/#56/#57/#58` の 2 周反復 smoke を実行した。worker gateway / verification / parent topology は全件 `Done` へ到達し、各周回後の watch/state は active / queued / blocked 0 だった。
  残課題:
  - current A3 がまだ使っていない command surface を parity 確認する
  - repeated scheduler-loop と長時間運用で read-after-write 揺れが追加 hardening を要しないか確認する。短時間の idle repeated observation と agent 正規経路の 2 周 mutation loop は完了済みで、残りはより長い時間窓の常駐 loop 観測である
  - Kanboard compatibility path は current default から外し、`KANBAN_BACKEND=kanboard` / `kanboard:*` の historical compatibility path として固定済み。物理削除は不要になった時点の別判断とする
  - A3 image から project 固有 JDK / Maven / verification runtime を剥がした状態で bundle doctor / smoke を継続確認する
  - `a3-agent` の JobRequest / JobResult / lifecycle / policy / transport を実装可能な粒度で固定する。特に HTTP transport では log/artifact を local path 参照ではなく A3-managed artifact store へ upload/stream する。Ruby domain 側では `AgentJobRequest` / `AgentJobResult` / upload-backed artifact reference / agent workspace descriptor の最小 contract を追加済みで、JSON-backed job store、file-backed artifact store、pull handler、artifact upload endpoint、`a3 agent-server` の最小 HTTP entrypoint、Ruby reference agent (`a3-agent`) の 1 job worker loop も追加済み。Go 側は `agent-go` module として 1 job worker loop を標準 library のみで build / test できる scaffold まで追加済み。さらに worker phase と HTTP pull agent を接続する `AgentWorkerGateway` を追加し、既存 worker request/result protocol を `WorkerProtocol` に抽出した。`agent-http` gateway は `same-path` と `agent-materialized` を明示 mode として扱い、agent job 完了後も worker protocol result を正本として validation / `changed_files` canonicalization を行う。verification は `AgentCommandRunner` と CLI `--verification-command-runner agent-http` で agent job 化できるようになり、focused smoke と bundle smoke で materialized workspace 上の remediation / verification command execution、log upload、cleanup を確認済み
  - workspace materialization / dirty check / cleanup の owner を agent runtime として実装し、A3 は source descriptor と workspace descriptor / evidence を検証する形に寄せる。Ruby `AgentWorkspaceRequest`、`AgentJobRequest.workspace_request`、Go `WorkspaceRequest` JSON shape、Go agent 側の `local_git` alias + `worktree_detached` materializer、HTTP worker loop への materializer 接続、worker protocol transport、A3-side `AgentWorkspaceRequestBuilder`、CLI の `--agent-shared-workspace-mode agent-materialized` / `--agent-source-alias` まで追加済み。`agent-go/scripts/smoke-materialized-worker-protocol.sh`、`agent-go/scripts/smoke-materialized-agent-gateway.sh`、`agent-go/scripts/smoke-materialized-command-runner.sh` で、Go agent の materialized workspace と A3 gateway / command runner の end-to-end path を確認済み。runtime package は A3 側の `slot -> alias` contract と worker gateway option summary を公開し、Go agent は runtime profile JSON (`alias -> local path`) と `a3-agent doctor -config ...` を持つ。`task a3:portal:bundle:agent-parent-topology-smoke` で synthetic `repo:both` parent と 2 child relation、parent integration ref の 2 slot materialization、agent-http parent verification、parent merge の `Done` 到達まで確認済み。`a3 agent-artifact-cleanup` と bundle task `a3:portal:bundle:agent-artifact-cleanup` で diagnostic/evidence artifact retention cleanup を追加済み。TTL に加え、count cap と size cap で disk pressure 時の上限を operator command から制御できる。次は production 配布 package 側の service install policy、TLS / authorization scope / token rotation、長時間運用 hardening を進める
  - Go single binary agent の scaffold と installer 方針を固定する。`agent-go/scripts/build-release.sh`、`agent-go/scripts/install-release.sh`、`agent-go/scripts/install-local.sh`、Ruby control plane との protocol smoke は追加済み。`build-release.sh` は cross-build した binary に加え、platform archive、`checksums.txt`、`release-manifest.jsonl` を生成できる。`install-release.sh` は Go のない target host で release archive から binary と任意 service template を install できる。さらに `a3-agent --loop --poll-interval ...` と `a3-agent service-template systemd|launchd` を追加し、daemon manager / container service から継続 poll できる入口と service-manager template generation を固定済み。local installer も `INSTALL_SERVICE=1` で template install、`ENABLE_SERVICE=1` で systemd/launchd の load/enable まで opt-in 実行できる。auth は agent-side token (`A3_AGENT_TOKEN` / `A3_AGENT_TOKEN_FILE` / `--agent-token` / `--agent-token-file` / profile `agent_token` / `agent_token_file`) と optional control-side token (`A3_AGENT_CONTROL_TOKEN` / `A3_AGENT_CONTROL_TOKEN_FILE` / `--agent-control-token` / `--agent-control-token-file`) による scoped bearer token を最小 contract として追加済み
  - Docker compose bundle を `docker:a3` + `docker:soloboard` + optional `docker:dev-env(a3-agent)` の形へ更新する。workspace root の bundle smoke で `a3-runtime` control plane から `a3-agent` service へ job を流し、result / artifact upload まで確認済み。さらに `task a3:portal:bundle:agent-worker-gateway-smoke` で `execute-until-idle --worker-gateway agent-http` が compose `a3-agent` 経由で implementation worker result を返し、実 SoloBoard task `Portal#37` を `Inspection -> Done` まで進められることを確認済み。`task a3:portal:bundle:agent-verification-smoke` では Portal dev-env agent image 経由で `run-verification --verification-command-runner agent-http` を実行し、remediation と verification の 2 command が agent job として成功し、実 SoloBoard task `Portal#39` が `Merging -> Done` へ進むことを確認済み。`task a3:portal:bundle:agent-parent-topology-smoke` では実 SoloBoard task `Portal#40/#41/#42` の parent/child relation を作成し、parent verification / merge を経て `Done` まで確認済み
  - Portal starters / UI app の単独 full verification は、それぞれ実 source repo で `a3-agent` 経由確認済み。`repo:both` parent topology canary は synthetic source repo で確認済み。実 Portal source の `repo:both` full verification は重い PR前/統合前 canary として扱う
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
  現状: root `README.md` / `AGENTS.md` を A3 前提の責務分担へ追従済み。legacy automation skills は削除済みで、現行運用 skill は kanban / scheduler / pre-commit 系に寄せた。
  根拠: root `README.md`, root `AGENTS.md`, `.agents/skills/*`

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
