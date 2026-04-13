# A3 Container Distribution and Project Runtime

対象読者: A3 設計者 / PJ manifest 設計者 / 運用者
文書種別: 設計メモ

この文書は、A3 を Docker コンテナとして配布し、案件ごとに利用可能にするための配布モデルと runtime packaging を定義する。
既存の domain rule や workspace rule を Docker 都合で崩さず、共通 image と案件固有 runtime を分離することを目的とする。

## 0. 進捗状況

この文書は設計メモであると同時に、container distribution / project runtime 領域の実装進捗の正本でもある。
kanban が追随していない期間でも、少なくともこの節を見れば現在地を確認できる状態を維持する。

### 0.1 現在地

- 状態
  - `a3-engine` live canary を 1 本完了し、A3 direct verification では `scratch` / `local-live` / `parent-child` の 3 類型で `To do -> Done` の正規フローを確認済み
- 完了済み
  - runtime package descriptor の主要 contract を実装済み
  - `doctor-runtime` / `show-runtime-package` / `run-runtime-canary` で inspection を確認可能
  - recovery (`show-run` / `show-blocked-diagnosis` / `recover-rerun`) から runtime package guidance を参照可能
  - `migrate-scheduler-store` を含む runtime startup surface を Portal runtime で実行確認済み
  - A3 scheduler manual surface (`scheduler:run-once` / `scheduler:pause` / `scheduler:resume` / `scheduler:control`) を workspace root から起動できる。macOS LaunchAgent service surface は current scope 外として削除済み
  - reference project で `plan-run-once` selectable な live handoff canary を 1 本通し、implementation / review / inspection / merge / live repo 反映まで確認済み
  - A3 から external kanban task を取り込み、`execute-next-runnable-task` で `To do` task を選定して `In progress` / `In review` / `Done` へ反映する direct bridge を実装済み
  - external task identity は `task_id` を正本キーとして扱い、duplicate `reference` があっても publish を誤らないよう修正済み
  - scheduler cycle 前に external kanban snapshot と reconcile する Kanban-first 運用を実装済み
  - single-repo / multi-repo の standalone task を A3 direct verification で `Done` まで反映済み
  - parent/child mixed topology の direct verification を A3 で `Done` まで反映済み
  - single-repo / multi-repo / parent-child の local-live diff canary を A3 で完走し、local `feature/prototype` への実差分反映まで確認済み
  - Portal fresh-5 canary (`Portal#3156/#3157/#3158`) を A3 で完走し、child から parent finalize まで `Done` を確認済み
  - Portal direct baseline canary (`Portal#3170/#3171/#3172`) を完走し、child merge 後に parent が review / verification / merge へ handoff されることを確認済み
  - Portal scheduler baseline canary (`Portal#3173/#3174/#3175`) を完走し、scheduler 経路でも child 2 件と parent 1 件が `Done` まで進むことを確認済み
  - scheduler-shot 正常終了時に `scheduler-shot.lock` が自動 cleanup されるよう修正し、`show-state` が `stale_shot_lock` を誤検知しないことを確認済み
  - `A3-v2#3031` / `#3119` / `#3150` / `#3151` / `#3159` は historical backlog ref として fresh-5 evidence をもって `Done` 化済み
  - legacy Portal scheduler (`task a3:portal:scheduler:*`) は fail-fast 化し、Portal 側の自動実行導線からは外した
  - recovery operator surface の `requires_operator_action` 経路を例外ではなく guidance 出力として扱うよう修正済み
  - SoloBoard local bundle は A3 runtime container と SoloBoard container を compose で起動し、runtime container 内から `watch-summary` / `show-state` / `execute-until-idle` を呼べるところまで確認済み。SoloBoard container は upstream GHCR image `ghcr.io/wamukat/soloboard:latest` を使い、local source checkout build には依存しない
  - 2026-04-12 に SoloBoard upstream latest を再 pull/recreate し、standalone と runtime の両方が image digest `sha256:e77c0ebcd4b49aed28ce1e97d89b2751f20249f438a870b874dbd1e1365e4191` / version `0.9.2` / revision `c5cd3f10a2c357e4d6b2e4328b2910e222307eda` で起動することを確認した。`task soloboard:doctor` / `soloboard:bootstrap` / `soloboard:smoke`、`task a3:portal:runtime:doctor` / `runtime:bootstrap` / `runtime:smoke`、`task a3:portal:runtime:host-agent-smoke` は成功しており、SoloBoard latest の API surface と A3 agent 接続は現行 adapter と互換である
  - bundle runtime の workspace / scheduler state は host bind mount 配下 `.work` ではなく Docker volume `/var/lib/a3` に置く方針へ変更済み。host `.work` へ git worktree を作ると Docker Desktop bind mount 上の `git reset` / Maven I/O が不安定化し、ディスク消費も読みづらくなるためである
  - SoloBoard bundle spike では Portal starters の Java 25 / google-java-format 1.34.1 前提に合わせて一時的に Temurin 25 JDK を A3 runtime image へ入れたが、これは完成形ではない。最新方針では A3 image から project 固有 JDK / Maven / verification runtime を剥がし、project runtime は `a3-agent` 側へ分離する
  - Portal dev-env agent image は検証 spike の履歴証跡として残すが、現行配布物からは外した。A3 release は `a3-engine` repo 内で管理し、A3 runtime image は `a3-engine/docker/a3-runtime/Dockerfile`、agent は `agent-go` release binary を host / project dev-env へ install する。Portal 固有 Java / Maven / Node runtime を A3 配布 Docker image へ含めない
  - 2026-04-11 の bundle 実チケット smoke では、`Portal#37` が worker gateway 経由で `Inspection -> Done`、`Portal#39` が agent verification command runner 経由で `Merging -> Done`、`Portal#40` が child `Portal#41/#42` を集約する parent topology で `Done` まで到達した。初回 `Portal#38` は synthetic non-Maven fixture で Maven bootstrap/prefetch を走らせたため blocked になったが、`47dda1f` で non-Maven verification slot では Maven bootstrap を skip するよう修正し、復旧コメントと blocked label removal 後に superseded canary として `Done` 化した
  - `task a3:portal:runtime:agent-real-parent-full-verification-smoke` で実 Portal live repo の `repo:both` parent/full verification canary を完走した。`Portal#88` parent と `Portal#89/#90` child を作成し、実 `member-portal-starters` / `member-portal-ui-app` live repo に parent smoke commit を作成した上で、starters 側 `gate:standard` / `test:all` / `test:nullaway` と ui-app 側 `gate:standard` / `test:nullaway` を agent-http 経由で実行し、parent merge が両 repo の `feature/prototype` を `refs/heads/a3/parent/Portal-88` へ更新することまで確認した
- 未完了
  - final scheduler validation で、current implementation が Git の自然な branch/worktree 階層をまだ正規モデルにできていないことを確認した。完成条件として、single / parent / child を dedicated branch + dedicated worktree model に統一する。single は live target から `refs/heads/a3/work/<single>`、parent は live target から `refs/heads/a3/parent/<parent>`、child は parent branch から `refs/heads/a3/work/<child>` を作成し、それぞれの worktree 上で実行する。detached checkout + `update-ref` 後同期は正規経路にしない
  - current `a3-agent` workspace request builder は、implementation で `edit_scope`、verification で `verification_scope` を slot list として使っており、`repo:ui-app` task で starters slot が materialize されない旧来 failure を再発させうる。完成条件として、agent job payload の `workspace_request.slots` は runtime package の全 repo source slot を常に含める。`repo:*` は編集対象 / access / sync class を決める入力であり、slot membership の filter として使わない
  - parent topology の cleanup は、parent `Done` 後に parent runtime workspace、parent branch worktree、配下 child ticket workspace、child branch worktree を cleanup policy に従って回収するところまでを completion gate に含める
  - worker invocation / Git backend の本格運用レベル整備
  - Redmine backend contract / bootstrap / adapter / cutover canary は現行計画から外し、SoloBoard 前提に再整理する
  - project integration で初めて見える個別調整の吸収
  - project verification 実装と repo-local gate のズレを継続棚卸しし、PMD `linkXRef` のような report-only 解決経路で parent verification が不安定化しないよう automation 向け hardening を進める
  - terminal task の workspace / artifact / log cleanup は operator command と scheduler idle cleanup まで実装済み。agent artifact store は diagnostic/evidence 別に TTL + count + size cap cleanup まで実装済み。2026-04-12 に runtime artifact cleanup dry-run と host cleanup dry-run を実行し、どちらも候補 0 の idle 状態を確認した。残りは logs / blocked diagnosis evidence の retention 仕様を長時間運用で実測すること
  - root cleanup は current scheduler quarantine / results / logs / project-local build output (`target/`, quarantine 配下 local `.work/m2/repository`, generated reports) の age+count+size retention と disposable cache の age+size retention まで拡張済みで、scheduler idle 後の terminal workspace cleanup も自動連携済み。2026-04-12 の `task a3:portal:cleanup` dry-run は `candidate_count=0`, `active_refs=[]` だった
- `.work` inventory も current/disposable の一次分類まで完了し、`live-targets` は bootstrap source として keep、`.work/a3/issues` は top-level path のみ legacy-compatible に維持して payload は delete 対象、`.work/a3/notifications` は low-value log として retention/delete 対象に固定した

### 0.1.0a Implementation gap TODO

設計継承監査で確認した implementation gap は、次を完了するまで current A3 の completion blocker として扱う。

- TODO-1: workspace slot universe
  - `WorkspacePolicy` は `edit_scope` / `verification_scope` ではなく runtime package の全 repo source slot を slot requirement 化する
  - `repo:*` label は edit ownership / sync class / publishable target の判定だけに使う
  - `verification_scope` を workspace materialization の slot filter として使わない
- TODO-2: agent workspace request full slots
  - `AgentWorkspaceRequestBuilder` は runtime package の全 repo source slot を `workspace_request.slots` に常時含める
  - request/slot contract は `sync_class` / ownership を表し、agent 側でも slot 欠落を fail-close できる
  - `repo:ui-app` task でも starters slot が materialize される focused regression を追加する
  - support slot は topology ごとに ref を解決する。single task の support slot は project live/base ref または slot-specific support ref を read-only で materialize する。parent task と child task の support slot は parent integration ref (`refs/heads/a3/parent/<parent>`) を read-only で materialize し、子が親 branch 上の全 repo snapshot を参照できる状態にする。`refs/heads/a3/work/<task>` は edit-target slot 専用であり、support repo には作らない
- TODO-3: dedicated branch worktree materialization
  - Docker + host/dev-env agent mode では、project repo の worktree 作成、branch checkout、dirty check、cleanup、quarantine は `a3-agent` が配置された runtime 側で行う
  - A3 Engine は control plane として `workspace_request` を作成し、`workspace_descriptor` / artifact / result を検証・記録する。Docker + host/dev-env agent mode では project repo の checkout / worktree 作成を行わない
  - Go agent materializer は正規経路を `worktree_branch` / dedicated branch checkout にする。Ruby `local_*` backend は legacy/direct compatibility adapter として扱い、主経路の完成条件にしない
  - `worktree_detached` / `git worktree add --detach` は正規 task workspace model から外す
  - single / parent / child の branch base と merge target を workspace request / descriptor で説明可能にする
  - `workspace_request.slots[*].bootstrap_ref` / `bootstrap_base_ref` を正規 contract とし、missing branch は agent materialize 時に topology に応じた base から作る。single work branch と parent integration branch は current live target から、child work branch は parent integration branch から作る。最初の child で parent integration branch も未作成の場合は、`bootstrap_base_ref` の live target から parent integration branch を先に作り、その parent branch から child work branch を切る
  - scheduler 起動時に batch 内の全 `a3/work/*` / `a3/parent/*` ref を live head へ一括 `update-ref` してはならない。これは先行 single merge 後に作られるべき parent branch が古い live head から始まる defect を隠すためである
- TODO-4: branch-native publish / merge
  - Docker + host/dev-env agent mode の implementation publish は agent-owned branch worktree 上の通常 commit とし、Engine 側の `git update-ref` 後同期を不要にする
  - implementation publish は `workspace_request.publish_policy.mode=commit_declared_changes_on_success` を正規 contract とする。agent は全 slot の worker result `changed_files` と実 worktree 差分を commit 前に照合し、一致した edit-target slot だけを commit する。commit 途中失敗時は先に進めた slot branch を rollback する。A3 Engine は `publish_status` / `publish_before_head` / `publish_after_head` / `resolved_head` を検証し、publish evidence がある場合は Engine 側 workspace へ patch を適用しない
  - merge は `merge_request` を正規 contract とする。A3 Engine は `--merge-runner agent-http` で merge job を control plane に投入し、Go agent が source alias repo 上で target branch worktree を作成して normal Git merge を実行する。agent は `merge_before_head` / `merge_after_head` / `resolved_head` / `project_repo_mutator=a3-agent` を返し、Engine は `AgentMergeRunner` で検証する
  - 2026-04-13 時点で implementation publish と native merge job の Go agent path は実装済み。Ruby Engine 側の direct project repo mutation 実装は削除し、未設定時は `DisabledWorkspaceChangePublisher` / `DisabledMergeRunner` で fail closed にする。agent-materialized verification / worker / merge は Engine workspace preparation を skip し、runtime smoke は `--verification-command-runner agent-http` / `--merge-runner agent-http` を明示して parent-child / single live merge の実チケット証跡を固定する
  - child merge は agent-owned parent branch worktree、single/parent merge は agent-owned live target branch worktree 上の normal Git merge とする
  - Engine は merge/publish job を発行し、agent が返す before/after head、merge evidence、artifact を検証する。Engine が host project repo に対して merge / commit / update-ref を直接実行しない
  - merge 後に detached parent workspace sync を行わない
- TODO-5: parent-child workspace topology in agent mode
  - agent-materialized child workspace は parent workspace 配下の `children/<child>/ticket_workspace` topology を使う
  - workspace descriptor / cleanup が parent root と child workspace の関係を追跡できる
  - parent `Done` cleanup が parent / child worktree と workspace を一貫して回収できる
- TODO-6: Portal Maven local repository policy
  - Portal の Maven local repository は単純な dependency cache として扱わない。`member-portal-starters` の `install` 成果物は `member-portal-ui-app` の verification 入力であり、task / parent integration branch の成果物として扱う
  - third-party dependency、Maven plugin、toolchain distribution、再取得可能な seed cache は shared dependency cache として共有候補にする
  - `member-portal-starters` の SNAPSHOT artifact、child branch 由来の install 成果物、parent integration branch 由来の install 成果物は scoped artifact store に置く
  - child verification は child-scoped local repo を使い、child workspace の starters worktree から install した artifact を ui-app が参照する
  - parent verification は parent-scoped local repo を使い、child merge 済み parent integration branch の starters worktree から install した artifact を ui-app が参照する
  - single verification は single-scoped local repo を使い、`repo:ui-app` task でも support slot として materialize された starters worktree から必要 artifact を install する
  - shared cache から scoped local repo への materialization は軽量化してよいが、scoped artifact を shared cache へ逆流させない
  - scoped local repo が見つからない、または owner descriptor が workspace / parent descriptor と一致しない場合は、live repo や global `~/.m2/repository` へ fallback せず fail-fast する
  - host-local runtime scheduler は `A3_MAVEN_WORKSPACE_BOOTSTRAP_MODE=empty` を agent job へ注入し、scoped local repo は作るが shared seed の全コピーは行わない。これにより starter install artifact の task/parent scoped isolation は維持しつつ、third-party cache 全量コピーによる disk pressure を避ける
  - この policy は Portal runtime から A3 へ注入する。A3 core は `member-portal-starters`、Maven groupId、`mvn install` の意味を固定知識として持たない

これらの TODO は設計メモではなく実装 backlog であり、各 TODO は実装後にサブエージェントレビューで「差分の正しさ」と「設計思想の反映」を確認してから完了扱いにする。

### 0.1.0 Runtime 実チケット smoke 証跡

2026-04-11 時点では、A3 runtime container、SoloBoard container、Portal dev-env `a3-agent` container を組み合わせた compose bundle で次の smoke を通していた。2026-04-13 の配布整理により、Docker dev-env agent image とその smoke task は現行配布から削除し、host-local `a3-agent` 経路を正規経路にした。以下は historical evidence として扱う。

- `task a3:portal:runtime:smoke`
  - `Portal#35` parent と `Portal#36` child を作成し、relation/comment/transition を含む compatibility surface を確認した
- `task a3:portal:runtime:agent-worker-gateway-smoke`
  - `Portal#37` を作成し、`execute-until-idle --worker-gateway agent-http` が compose `a3-agent` 経由で implementation worker result を返し、最終的に `Done` へ到達した
- `task a3:portal:runtime:agent-verification-smoke`
  - 初回 `Portal#38` は synthetic non-Maven fixture に対して Maven bootstrap/prefetch を実行したため blocked になった
  - `47dda1f` で non-Maven verification slot では Maven bootstrap/prefetch を skip するよう修正した
  - 再実行した `Portal#39` は remediation job と verification job がどちらも agent-http command runner 経由で成功し、`Merging -> Done` へ到達した
- `task a3:portal:runtime:agent-parent-topology-smoke`
  - `Portal#40` parent と `Portal#41/#42` child を作成し、parent integration ref を `repo:both` の 2 slot に materialize した
  - parent verification と parent merge が agent-http / materialized workspace 経由で成功し、親子とも `Done` へ到達した
- `task a3:portal:runtime:agent-real-parent-full-verification-smoke`
  - 初回は当時の Portal dev-env agent image に `ripgrep` がなく、starters knowledge catalog build が `FileNotFoundError: rg` で失敗したため、当時の Dockerfile に `ripgrep` を追加した
  - 次に `test:all` で fresh workspace Maven repo 内の `mockito-core-5.17.0.jar` が不正 JAR として検出されたため、Maven repo bootstrap で manifest なし JAR を削除し、Portal verification が Mockito agent を事前取得・検証・再取得するよう hardening した
  - 再実行した `Portal#79` parent と `Portal#80/#81` child は、実 Portal source 由来の isolated clone に対する `repo:both` parent/full verification と parent merge を agent-http / materialized workspace 経由で完了し、親子とも `Done` へ到達した
  - live repo への merge 証跡を固定するため、`portal` mode の repo source を isolated clone から `/workspace/member-portal-starters` / `/workspace/member-portal-ui-app` に切り替えた。`Portal#88` parent と `Portal#89/#90` child は、live repo 上の `refs/heads/a3/parent/Portal-88` に smoke commit を作成し、full verification 成功後に両 repo の `feature/prototype` がその commit へ更新されたことを reflog と marker file で確認した
- `task a3:portal:runtime:observe`
  - runtime の反復観測入口として追加した
  - 各 iteration で UTC 時刻、host disk、Docker reclaimable、runtime doctor、watch-summary、show-state を `.work/a3/portal-bundle/observation.log` へ記録する
  - 観測中の command failure は `pipefail` で task failure として扱い、ログだけ成功扱いにしない
- `task a3:portal:runtime:archive-state`
  - runtime canary storage に古い blocked / failed run が残っている場合、削除ではなく `/var/lib/a3/archive/<storage-name>-<UTC timestamp>` へ退避してから空の state を作る
  - SoloBoard の ticket/comment/relation data は変更しない
- `task a3:portal:runtime:agent-loop` (historical; removed)
  - agent 正規経路の反復観測入口として追加した
  - 各 iteration で `agent-worker-gateway-smoke`, `agent-verification-smoke`, `agent-parent-topology-smoke` を順に実行し、label / transition / relation / done confirmation を含む mutation 経路を繰り返す
  - 各 iteration の前後で disk / Docker reclaimable / runtime doctor / watch-summary / show-state を `.work/a3/portal-bundle/agent-loop.log` へ記録する

この smoke 群は `docker:a3 + docker:soloboard + docker:dev-env(a3-agent)` 形状が成立していた historical evidence である。現行配布形状は `docker:a3 + docker:soloboard + host/project-dev-env a3-agent binary` であり、Docker dev-env agent image は配布対象外である。

2026-04-11 の反復観測:

- `ITERATIONS=6 INTERVAL_SECONDS=30 task a3:portal:bundle:observe` を実行し、約 3 分間、全 iteration で `active_runs=0`, `queued_tasks=0`, `blocked_tasks=0` を確認した
- host disk は 93Gi 空き、Docker build cache reclaimable は 667.2MB で推移し、観測中の増加は見られなかった
- その後、diagnostic canary として `Portal#43` を legacy direct `bundle:run-once` に流したところ、implementation は通ったが verification が docker:a3 内の `portal_remediation.rb` で project runtime を要求し blocked になった
- この結果を受け、`portal_remediation.rb` / `portal_verification.rb` は slot cwd から workspace root を解決できるよう修正した。後続の整理で legacy direct `bundle:run-once` / `runtime:run-once` entrypoint は削除し、Docker A3 から project verification を直接実行する経路は通常 surface から外した
- `Portal#43` は diagnostic canary として recovery comment を残し、blocked label を外して `Done` 化した。A3 internal canary storage は `/var/lib/a3/archive/portal-soloboard-bundle-canary-20260411T142541Z` へ退避し、再観測で `active_runs=0`, `queued_tasks=0`, `blocked_tasks=0` を確認した
- `ITERATIONS=1 INTERVAL_SECONDS=5 task a3:portal:bundle:agent-loop` を実行し、`Portal#44` worker gateway、`Portal#45` verification、`Portal#46/#47/#48` parent topology がすべて `Done` へ到達した
- `ITERATIONS=2 INTERVAL_SECONDS=10 task a3:portal:bundle:agent-loop` を追加実行し、1 周目は `Portal#49/#50/#51/#52/#53`、2 周目は `Portal#54/#55/#56/#57/#58` がすべて `Done` へ到達した。各周回後の `watch-summary` / `show-state` は `active_runs=0`, `queued_tasks=0`, `blocked_tasks=0` で、label / transition / relation / done confirmation の read-after-write false negative は再現しなかった
- 反復 agent-loop 後も host disk は 93Gi 空き、Docker build cache reclaimable は 667.2MB、bundle volumes は約 115MB で推移した

注意: legacy direct-path diagnosis 用の `bundle:run-once` / `runtime:run-once` は削除済みである。A3 runtime container には project 固有 Java/Maven runtime を持たせない方針のため、Docker A3 から Portal verification を直接実行する経路は通常 surface に戻さない。worker/verification/parent topology の検証は host-local `a3-agent` 経路を正規経路とする。

### 0.1.1 実装済みと未実装の切り分け

2026-04-06 時点では、A3 は「core が未着手」ではなく、「core はかなり揃っているが Portal scheduler の実運用接続が未完」という状態だった。2026-04-11 時点では scheduler / SoloBoard / agent smoke まで進み、残りは配布・長時間運用 hardening 側へ移っている。

- 実装済み
  - runtime package / doctor / recovery / migrate-scheduler-store の core surface
  - external kanban bridge と `task_id` 基準の reconcile
  - `execute-until-idle` による direct execution
  - standalone / multi-repo / parent-child の direct verification 完走
  - local-live diff canary による live repo 反映
  - terminal workspace cleanup command
- 実装済みだが長時間運用 hardening が残るもの
  - worker invocation contract 自体の stdin bundle 標準化
  - `a3-engine` から worker command を受け取る経路
  - project command execution を host / dev-env 側 `a3-agent` へ寄せる transport と artifact upload
- 未実装 / 未完
  - `a3-agent` の長時間運用 hardening。`a3-agent --loop --poll-interval ...` と manual loop runbook は整理済みで、OS service template / install / load / enable は標準導線から外す。auth も local token file の最小 contract は実装済みで、2026-04-12 の 3 iteration bundle observe では idle / disk / Docker reclaimable が安定していることを確認した。残りは failure recovery と blocked diagnosis evidence retention の実測確認である。中央 A3 server / remote multi-agent pool / remote TLS termination は現行スコープ外とする
  - SoloBoard 前提の bootstrap / task 作成 / tag / lane 整備の配布導線固定
  - Kanboard compatibility path は削除する。current kanban backend は SoloBoard のみとし、過去の Kanboard canary は履歴証跡として文書にだけ残す
  - 実 Portal source の `repo:both` parent/full verification canary は完了済み。今後は同 canary を regression smoke として維持する
  - `.work` / artifact / logs / blocked diagnosis evidence retention の長時間運用検証

したがって、2026-04-12 時点の次優先は新しい trigger や検証専用概念を増やすことではない。A3 product/runtime 側で得た canary evidence と manual loop runbook を前提に、SoloBoard 前提の配布導線と retention/hardening を閉じることである。

### 0.1.1a 配布 runbook

2026-04-13 時点の配布 runbook は、`docker:a3 + docker:soloboard + host/project-dev-env a3-agent binary` を標準形状として扱う。A3 container は汎用 control plane であり、Portal 専用 JDK / Maven / Node runtime を持たない。project command は host または project dev-env container に install した `a3-agent` が担当する。A3 release に含める Dockerfile は `a3-engine/docker/a3-runtime/Dockerfile` を正本とし、workspace root 直下の `docker/a3-agent` / `docker/a3-portal-agent` image は削除済みである。

現行 A3 は local-first runtime である。A3 / SoloBoard / `a3-agent` は同一端末、または同一 Docker compose / project dev-env network 内で動く前提に固定する。A3 server を中央に置き、複数端末の remote agent が接続して自動処理する構成は、現在の state / job queue / artifact store / workspace descriptor のデータ構造では前提にしていない。

標準導入順は次のとおりである。

1. runtime 起動
   - `task a3:portal:runtime:up`
   - `task a3:portal:runtime:bootstrap`
   - `task a3:portal:runtime:doctor`
   - `doctor` が SoloBoard `/api/boards`、runtime container の `ruby` / `python3` / `task` を確認する
2. SoloBoard 初期化
   - bootstrap は `Portal` / `OIDC` / `A3Engine` board、lane、tag を seed する
   - `task kanban:doctor` と `task kanban:smoke` で generic operator surface を確認する
3. agent 設置
   - host 実行では `a3-engine/agent-go/scripts/install-release.sh <archive>` で release binary を install する
   - dev-env container 実行では project dev-env image へ同じ release binary を組み込む
   - runtime profile は `agent`, `control_plane_url`, `agent_token_file`, `workspace_root`, `source_aliases` を持つ
   - 標準起動は `a3-agent -config <profile> --loop --poll-interval 2s` を operator terminal または dev-env container で実行する
   - OS service 化は現行完成条件から外す。必要な場合は operator が A3 の外側で manual loop command を wrapper 化する
4. agent 疎通確認
   - `a3-agent doctor -config <profile>`
   - `task a3:portal:runtime:host-agent-smoke`
   - `task a3:portal:runtime:host-agent-parent-topology-smoke`
5. 反復観測
   - `ITERATIONS=<n> INTERVAL_SECONDS=<sec> task a3:portal:runtime:observe`
   - disk / Docker reclaimable / watch-summary / show-state は `.work/a3/portal-bundle/*.log` に残す
6. retention / cleanup
   - stale internal state は削除ではなく `task a3:portal:runtime:archive-state` で `/var/lib/a3/archive/...` へ退避する
   - agent artifact store は `task a3:portal:runtime:agent-artifact-cleanup -- --dry-run` で候補確認し、必要時だけ `--apply` する
   - host `.work` や Docker build cache は operator cleanup の対象であり、SoloBoard ticket data とは分離して扱う

manual loop の標準 profile 例:

```json
{
  "agent": "host-local",
  "control_plane_url": "http://127.0.0.1:7393",
  "agent_token_file": "/run/secrets/a3-agent-token",
  "workspace_root": "/workspace/.work/a3-agent-workspaces",
  "source_aliases": {
    "member-portal-starters": "/workspace/member-portal-starters",
    "member-portal-ui-app": "/workspace/member-portal-ui-app"
  }
}
```

host 上で agent を動かす場合、`control_plane_url` は `http://127.0.0.1:<published-port>` のような loopback URL にする。project dev-env container 内で agent を動かす場合、`http://a3-runtime:<port>` のような compose service name を使う。`source_aliases` は agent が実際に見える local path であり、A3 job payload の repo slot から直接 host path を推測しない。

host-local agent へ worker / verification / remediation job を委譲する場合、A3 runtime container 内の `A3_ROOT_DIR=/workspace` をそのまま渡してはいけない。host agent は host filesystem 上で command を実行するため、A3 runtime は `--agent-env A3_ROOT_DIR=<host workspace root>` を明示し、`ruby "$A3_ROOT_DIR/scripts/a3-projects/portal/portal_verification.rb"` のような project helper が host 側で解決できる状態にする。

#### 0.1.1a.1 Final validation variation matrix

A3 完成前の最終確認では、毎回重い実 Portal full verification を実行しない。通常は軽量な protocol / topology / retention smoke を回し、完成判定または大きな runtime 変更時だけ実 Portal source の heavy canary を実行する。

標準バリエーション:

- `T0 runtime lifecycle`: `task a3:portal:runtime:up`, `:bootstrap`, `:doctor` で Docker 上の A3 runtime、SoloBoard latest image、published agent port を確認する
- `T1 host-local agent protocol`: `task a3:portal:runtime:host-agent-smoke` で Docker 上 A3 control plane と host local `a3-agent` の pull / command execution / artifact upload / result submit を確認する
- `T2 host-local worker / command gateway`: scheduler run-once で implementation / verification / merge job が host local `a3-agent` 経由で A3 に戻ることを確認する
- `T3 host-local parent topology`: parent / child relation、repo:both slot、parent verification、merge が host local `a3-agent` 経由で `Done` まで進むことを `task a3:portal:runtime:host-agent-parent-topology-smoke` で確認する
- `T5 retention / recovery`: `task a3:portal:runtime:agent-artifact-cleanup -- --dry-run`, `task a3:portal:runtime:observe`, archived blocked diagnosis の `show-run` / `show-blocked-diagnosis` で診断可能性と disk pressure 対応を確認する
- `T6 real source single / parent verification`: project source / toolchain 変更時または PR 前の重点確認として、scheduler run-once による実 Portal source ticket を実行する
- `T7 real source repo:both parent full verification`: 完成判定または release candidate 判定で 1 回実行する heavy canary とし、日常 smoke の必須条件にはしない

完成条件は `T0` から `T5` が host-local agent を主経路にした軽量 smoke として安定し、`T6` / `T7` を必要タイミングで通せる運用証跡があることとする。`T7` は「A3 が実 Portal source を扱えるか」の最終証跡であり、「毎回実行する回帰テスト」ではない。

manual loop の運用ルール:

- 起動前に `a3-agent doctor -config <profile>` を必ず実行し、profile、control-plane URL、workspace root、source aliases を検証する
- 起動は `a3-agent -config <profile> --loop --poll-interval 2s` を標準とする。短時間 smoke のみ `--max-iterations` を使う
- 停止は operator terminal の `Ctrl-C` を標準とする。強制 kill 後は `task a3:portal:runtime:describe-state` と `task a3:portal:runtime:watch-summary` で active / queued / blocked を確認する
- loop が非 0 exit した場合は、A3 側の `agent_jobs.json` と uploaded combined log を見てから再起動する。job result が submit 済みか不明な場合は、同じ agent を即再起動する前に `describe-state` を確認する
- token は process arguments へ露出させず、`agent_token_file` を優先する。token rotation は file の atomic replace で行い、長時間起動中の agent は request ごとに token file を読み直す
- remote HTTP は標準運用に含めない。`allow_insecure_remote` は diagnostic escape hatch であり、配布 runbook へ載せない

通常運用時の確認コマンド:

```bash
task a3:portal:runtime:doctor
task a3:portal:runtime:watch-summary
task a3:portal:runtime:describe-state
ITERATIONS=3 INTERVAL_SECONDS=30 task a3:portal:runtime:observe
```

disk pressure 時の cleanup 判断:

- まず `df -h .` と `docker system df` で host disk と Docker reclaimable を見る
- A3 internal state は消さず、必要なら `task a3:portal:runtime:archive-state` で archive へ退避する
- agent artifacts は `task a3:portal:runtime:agent-artifact-cleanup -- --dry-run` で候補確認し、diagnostic / evidence の TTL・count・size cap を指定して `--apply` する
- SoloBoard volume は ticket/comment/relation の実データを持つため、通常 cleanup 対象にしない
- Docker image/build cache は再 pull / rebuild 可能な cache として扱えるが、`docker system prune -a --volumes` は SoloBoard data volume も消し得るため通常手順に入れない

禁止/注意:

- legacy direct-path diagnosis 用の `task a3:portal:runtime:run-once` / `task a3:portal:bundle:run-once` は削除済み。Docker A3 から project verification を直接実行する entrypoint は戻さない
- A3 image に project 固有 JDK / Maven / verification runtime を戻さない
- `JobResult` へ host/container local path だけを返さない。log / artifact は A3-managed artifact store へ upload し、A3 側で解決可能な artifact id を返す
- SoloBoard は bundled kanban だが A3 state store ではない。board/lane/tag/ticket/comment/relation は kanban surface として adapter 経由で扱う
- remote agent / central A3 server / multi-machine worker pool は現行スコープ外。remote TLS や remote agent authorization scope は今回の完成条件に含めない

#### 0.1.1b Operator command surface inventory

2026-04-12 の棚卸しでは、A3 CLI command と root `task a3:*` / `task soloboard:*` entrypoint を突き合わせ、通常 operator surface と低レベル internal surface を分けた。

通常 operator が使う入口:

- SoloBoard bootstrap / doctor / smoke: `task soloboard:doctor`, `task soloboard:bootstrap`, `task soloboard:smoke`, generic `task kanban:*`
- runtime lifecycle / observation: `task a3:portal:runtime:up`, `:doctor`, `:bootstrap`, `:watch-summary`, `:describe-state`, `:observe`, `:archive-state`, `:down`, `:logs`
- agent 正規経路 smoke: `task a3:portal:runtime:host-agent-smoke`, `:host-agent-parent-topology-smoke`, `:scheduler:run-once`
- cleanup / retention: `task a3:portal:cleanup`, `task a3:portal:runtime:agent-artifact-cleanup`
- runtime inspection: `show-project-surface`, `show-project-context`, `show-phase-runtime-config`, `show-runtime-package`, `doctor-runtime`, `migrate-scheduler-store`, `show-scheduler-state`, `show-scheduler-history`
- recovery inspection: `show-task`, `show-run`, `show-blocked-diagnosis`, `plan-rerun`, `recover-rerun`, `diagnose-blocked`, `repair-runs`, `cleanup-terminal-workspaces`, `quarantine-terminal-workspaces`

2026-04-12 の scratch 実測:

- `show-project-surface`, `show-project-context`, `show-phase-runtime-config`, `show-runtime-package`, `migrate-scheduler-store`, `show-scheduler-state`, `show-scheduler-history` は `/var/lib/a3/operator-surface-scratch-20260412` で成功し、scratch は削除済みである
- archived `Portal#43` blocked run を `/var/lib/a3/recovery-surface-scratch-portal-43-20260412` に複製し、`show-task`, `plan-rerun`, `recover-rerun`, `diagnose-blocked`, `show-blocked-diagnosis` を実行できることを確認した。`diagnose-blocked` は scratch にのみ診断を追記し、archive 正本は変更していない。scratch は削除済みである
- low-level phase execution commands (`run-worker-phase`, `run-verification`, `run-merge`) は direct operator command として個別実行するより、agent smoke / parent topology smoke / live repo full verification smoke の中で確認する
- low-level run mutation commands (`start-run`, `complete-run`, `prepare-workspace`, `execute-next-runnable-task`, `execute-until-idle`, `run-runtime-canary`) は runtime internals / smoke harness 用であり、通常 operator runbook の入口にはしない
- `pause-scheduler` / `resume-scheduler` は root の `task a3:portal:scheduler:pause/resume/control` から扱う。bundle 標準は operator terminal での manual loop 起動/停止であり、OS service 化は current scope 外である。macOS LaunchAgent 用の `a3:portal:scheduler:install/uninstall/reload/status` と `scripts/a3/launchd.rb` は削除済みで、`a3-agent` の scheduler 登録機能としては扱わない

この分類により、「operator が日常的に使う入口」は root Taskfile と bundle task に寄せ、A3 CLI の低レベル command は smoke harness / diagnosis / recovery の実装面として扱う。

命名上の残課題: `bundle` は実装由来の呼称であり、operator には「Docker 上 A3 runtime + SoloBoard + host/dev-env agent を使う local runtime」という意味が伝わりにくい。A3 Engine 自体は Docker 上で動かすことを主眼に置くため、operator-facing な `runtime` は自動的に `A3 Engine on Docker` を指すものとして扱う。したがって root Taskfile の public entrypoint は `a3:portal:bundle:*` から `a3:portal:runtime:*` へ rename する。移行時は短期間だけ旧名を maintenance alias として残し、docs / operator logs / watch-summary の表記から `bundle` を順次外す。

命名判断:

- 採用: `a3:portal:runtime:*`
  - operator には A3 の通常実行環境として見せる
  - 現行 scope では Docker compose 上の A3 runtime / SoloBoard を指す
  - `host-agent` / `local-agent` は agent 側 task 名で明示する
- 不採用: `a3:portal:docker-runtime:*`
  - 正確だが、A3 の標準 runtime が Docker であるという前提を毎回名前に出しすぎる
- 不採用: `a3:portal:local-runtime:*`
  - local-first であることは表せるが、A3 Engine が Docker 上で動く点が曖昧になる

### 0.1.2 2026-04-08 v1 / legacy 破棄可否の現状判定

live canary と scheduler surface の検証結果に加え、workspace root の operator surface / Python utility の棚卸しと Ruby migration を進めた結果、A3 は `legacy scheduler や root Python thin tooling がないと Portal canary を進められない` 段階を抜けた。2026-04-11 時点では `a3-v2/` source tree と legacy automation scripts も削除済みであり、現時点の未完は runtime の正当性よりも、配布・agent 運用・retention hardening の整理である。

- A3 product/runtime 側で達した状態
  - direct verification と fresh canary を A3 側の経路で完走できる
  - Portal 向け legacy scheduler 入口は fail-fast 化済み
  - root local utility は `run.rb` を含め Ruby へ移行済みで、`scripts/a3` 直下の Python script は retire 済み
- まだ残っている依存の種類
  - root-managed kanban adapter と compatibility launcher config
  - historical backlog 上の `A3Engine` 前提 relation / close 条件
  - historical cutover / parity 文書

結論として、2026-04-11 時点の判断は次のとおりである。

- Portal canary を進めるために v1/legacy を使う必要はない
- workspace root の現役 operator surface も Python / v1 依存からは外れた
- `a3-v2/` source tree と `legacy automation scripts` は削除済みであり、実行経路としては維持しない
- `A3-v2#2949` 系 backlog の close judgment は fresh-5 evidence で完了し、以後 `A3Engine` issue は設計参照にだけ残す
- 次は `SoloBoard 前提の配布導線` と `manual loop / retention hardening` を進める。Kanboard compatibility path は current runtime から削除済みであり、実 Portal source の `repo:both` parent/full verification canary は regression smoke として維持する

### 0.1.3 Compatibility Residual Inventory

`A3-v2#3160` では、workspace root に残っていた compatibility 資産を `retire / delete / keep` に分けて扱い、2026-04-11 時点で次のように整理した。

- `retire`
  - `Taskfile.yml` 上の disabled な `a3:portal:*` / `a3:portal-dev:*` sentinel task 群
  - help / runbook / README / AGENTS 上で日常入口のように見える obsolete alias の案内
- `delete`
  - `a3-v2/` source tree
  - `.agents/skills/a3-v2-checkpoint-review`
  - `scripts/automation/*`
  - legacy automation 向け skill / runbook / redesign メモ
  - root surface では `task automation*` を fail-fast sentinel とし、実行系 / mutation 系 entrypoint は残さない
- `keep`
  - `scripts/a3-projects/portal/config/portal-dev/*`
  - `portal-dev` root local utility
  - `scripts/a3-projects/portal/bootstrap_portal_dev_repos.rb`
  - `scripts/a3-projects/portal/prepare_portal_runtime_config.rb`

判断理由は次のとおりである。

- `retire`
  - 誤って踏まれると legacy / v1 経路の再実行を招くため、root surface から先に除去した
- `delete`
  - `a3-v2/` と `scripts/automation/*` は current operator surface では実行しないため、git history へ委ねて物理削除した
- `keep`
  - `portal-dev` root local utility / config と `bootstrap_portal_dev_repos.rb` は synthetic stale cleanup / maintenance utility / related spec からまだ参照される
  - `scripts/a3-projects/portal/prepare_portal_runtime_config.rb` は `portal` doctor-env / cleanup / reconcile の internal helper と related spec からまだ参照される

この時点で `A3-v2#3160` の acceptance は満たしており、compatibility 資産の扱いは「retire したもの」「delete 済みのもの」「current root utility を支えるため keep するもの」に分かれた。2026-04-12 の判断で Kanboard compatibility path も current runtime から物理削除する。以後の残件は、A3 / SoloBoard / a3-agent 配布導線を固定し、実 Portal source の `repo:both` parent/full verification canary を完了条件として通すことである。

### 0.2 直近の実装証跡

container distribution / project runtime で直近に積んだ主な commit:

- `9b6c3a8` `Extract runtime CLI output formatter`
- `90be383` `Add operator action commands to runtime flows`
- `7d50906` `Expose recovery doctor and runtime commands`
- `2c16734` `Expose recovery contract health and action summaries`
- `0164567` `Expose runtime retention policy across inspection flows`
- `b904f66` `Expose runtime materialization and configuration contracts`
- `fda513c` `Expose runtime log paths in inspection outputs`
- `a2d41a0` `Expand runtime persistent state roots`
- `a00f0a6` `Expose runtime branch and repository metadata contracts`
- `b26b274` `Expose runtime credential boundary contracts`
- `fb081c2` `Expose runtime observability boundaries`
- `51c47dc` `Fix A3 runtime canary readiness and CLI shape`
- `6d6452a` `Add A3-v2 kanban bridge for direct execution`
- `755c8a6` `Generalize kanban bridge test fixtures`
- `f40a38b` `Finish A3-v2 direct completion path for standalone tasks`
- `9a02aa1` `Allow project-specific live target refs in A3-v2`
- `68b169e` `Finalize A3-v2 live-write canary completion flow`
- `e0244c1` `Support both-repo local live diff canaries`
- `743a1a2` `Preserve tasks outside filtered Kanban snapshots`
- `8f412ec` `Retain Kanban task labels when reconciling tasks`
- `a4ee356` `Resolve Kanban relation refs in task snapshots`
- `bdb2ec9` `Return operator recovery guidance for rerun decisions`

### 0.3 Live Canary Evidence

reference project を使った thin live canary の現時点の証跡:

- canary 類型
  - single-repo live handoff canary
- confirmed
  - project validation
  - runtime doctor
  - context inspection
  - one-shot planner selection
  - one-shot execution
  - active run / scheduler state inspection
- observed result
  - planner selection から live handoff まで到達した
  - implementation / review / inspection はすべて `completed` まで到達した
  - merge rerun 後、reference project の live branch へ fast-forward できた
  - external kanban status は `Done` まで到達した

### 0.3.1 Live Gap Summary

reference project の live handoff canary で観測した integration gap と、その分類:

- product-side / A3 engine
  - review launch が `completion_requirements` の cross-repo access を満たす workspace guarantee を持っていなかった
  - merge launch が single-repo merge でも cross-repo support checkout を保証していなかった
  - merge inventory guard が follow-up task を merge child と区別できず、`child_without_commit_inventory` で parent merge を止めた
  - scheduler pause / launchd service 不在時、`launch_started` の見かけ上 stale な状態が残りやすかった
- project-side / reference project
  - project 固有の UI test command が live issue workspace で失敗した
  - これは project 側 follow-up で修正済み

直近で product-side へ反映済みの対応:

- `a3-engine: 24024d4`
  - merge bootstrap の `required_repo_ids` を merge phase 全 repo に広げ、support repo を保証
- review/inspection/merge の cross-repo live gap は `A3-v2#3031` で継続管理する

### 0.3.2 Verification Boundary Clarification

ここまでで確認した live canary は、A3-v2 の設計検証に使える材料ではあるが、実行主体は `a3-engine` だった。

- `a3-engine`
  - live kanban / scheduler / phase handoff / implementation-review-inspection-merge の既存 automation 実行系
- `A3-v2`
  - runtime package / doctor / recovery / runtime canary contract を直接検証すべき product 側

したがって、以後 `A3-v2` の検証と呼ぶものは、`a3-engine` の live canary ではなく、`a3-v2/bin/a3` を直接使う。

reference project 入力を使う A3-v2 直実行入口:

- runtime package inspection entrypoint
- runtime doctor entrypoint
- runtime canary entrypoint

A3-v2 direct verification で確認済みの類型:

- single-repo standalone task
  - `show-runtime-package` / `doctor-runtime` / `execute-until-idle` を A3-v2 から直接実行し、`To do -> Done` を確認済み
- multi-repo standalone task
  - `show-runtime-package` / `doctor-runtime` / `run-runtime-canary` / `execute-until-idle` を A3-v2 から直接実行し、`To do -> Done` を確認済み
- mixed parent/child topology
  - `plan-next-runnable-task` / `execute-until-idle` / `run-merge` を A3-v2 から直接実行し、child 完了集約から parent finalize まで `To do -> Done` を確認済み
- mixed parent/child local-live diff topology
  - `Portal#3052` / `Portal#3053` / `Portal#3054` で、child ごとの implementation diff を local work ref に publish し、child merge-to-parent と parent merge-to-live を通して local `feature/prototype` へ反映できることを確認済み

この direct verification では `a3-engine` scheduler / live handoff を使わず、workspace root 側の manifest / repo source / secret injection を通じて `a3-v2/bin/a3` を直接起動する。

### 0.3.3 A3-v2 Scheduler Surface Clarification

A3-v2 には scheduler がある。今回の混同は `legacy A3` (`task a3:portal:scheduler:*`, `scripts/a3/run.rb ...`) と `A3-v2` (`task a3:portal-v2:scheduler:*`, `a3-v2/bin/a3 ...`) の入口が workspace root に並存していることが原因だった。

- legacy A3 scheduler
  - `task a3:portal:scheduler:*`
  - `ruby scripts/a3/run.rb ...`
  - `a3-engine` / legacy automation 実行系の scheduler
- A3-v2 scheduler
  - `task a3:portal-v2:scheduler:run-once`
  - `task a3:portal-v2:scheduler:install`
  - `task a3:portal-v2:scheduler:reload`
  - `task a3:portal-v2:scheduler:status`
  - `ruby -I a3-v2/lib a3-v2/bin/a3 execute-until-idle ...`

以後 `A3-v2 scheduler` と呼ぶ対象は後者だけとし、Portal backlog の自動実行検証では `task a3:portal:scheduler:*` を使わない。

現時点の整理:

- A3-v2 scheduler は実装対象外ではない
- one-shot (`execute-until-idle`) だけでなく、workspace root 経由の scheduler launch surface も存在する
- scheduler が見る trigger は Portal 既存の `trigger:auto-implement` / `trigger:auto-parent` のみとし、scheduler 専用 trigger は持ち込まない
- `scratch` / `local-live` / `parent-child` は direct verification の検証類型であり、scheduler の task 選定概念にはしない
- operator 向け導線はまだ弱く、legacy 入口と混同しやすいので、この文書を正本として起動入口を固定する
- workspace root に残る Portal 向け thin tooling (`portal_v2_scheduler_launcher.rb`, `portal_v2_watch_summary.rb`, bootstrap / helper 群) は暫定実装と位置づけ、scheduler launcher 以外の residual を順次 Ruby CLI へ寄せる

これらは workspace root 側の project-specific injection であり、A3-v2 本体へ案件知識を持ち込まない。

今回の direct completion で product-side に反映した gap:

- external kanban から取り込んだ standalone task が `child` として import され、`merge_to_live` を通れなかった
  - standalone task は `single` として import するよう修正
- runtime workspace の `branch_head` repo source で missing branch ref を bootstrap できず、review/runtime phase の materialization が失敗した
  - `branch_head` source 全般で missing ref bootstrap を許可するよう修正
- direct verification 用の scratch repo source へ切り替えた後、quarantine cleanup が `git worktree remove` 前提のまま stale path を消せずに失敗した
  - 未登録 path は plain directory cleanup へ fallback するよう修正
- mixed parent/child の child merge で、`merge_to_parent` target ref が canonical slug 化されず、`PhaseSourcePolicy` の integration ref と一致しなかった
  - `merge_to_parent` target ref も parent task ref 由来の canonical slug へ正規化するよう修正
- mixed parent/child の最初の child merge で、親 integration branch が scratch repo source にまだ存在せず `rev-parse` で失敗した
  - 当時の direct merge runner が `refs/heads/a3/parent/*` を `refs/heads/live` から bootstrap できるよう修正。2026-04-13 以降、この direct merge 実装は削除済みで、同責務は a3-agent が持つ
- project-scoped live target ref を導入した後、mixed parent/child の local-live child merge では親 integration branch bootstrap がまだ `refs/heads/live` 固定で、`refs/heads/feature/prototype` を持つ project で失敗した
  - merge plan に bootstrap ref を持たせ、direct runner が `merge_to_parent` でも project-scoped live target ref を使って親 integration branch を bootstrap できるよう修正。2026-04-13 以降、この direct merge 実装は削除済みで、同責務は a3-agent が持つ
- `run-merge` / `run-verification` / `run-worker-phase` の CLI parser が kanban bridge option を受けず、open run recovery を A3-v2 direct verification で再利用できなかった
  - phase recovery CLI でも `--kanban-*` / repo label mapping を受けるよう修正

### 0.4 この文書で管理する残作業

この節で追う残作業は次に限定する。

- product 側で閉じられる runtime package / inspection / recovery / canary contract の残差
- live canary で観測された product-side gap の是正
- 次の live canary に入れる target shape の固定
- A3-v2 scheduler operator 導線の明確化
  - legacy scheduler との混同を避ける入口整理
  - watch / status / run-once の運用導線固定
  - run evidence を正本にした operator log/watch surface の仕上げ

関連する kanban task:

- `A3-v2#3031`
  - live canary / fresh-5 evidence の intake 親 task
  - 2026-04-08 時点で `Done`
- `A3-v2#3048`
  - external kanban task source / status bridge の実装と direct verification の一次受け
  - task 自体は完了済みだが、履歴上の起点としてここに残す
- `A3-v2#2949`
  - worktree migration foundations の親 task
  - 2026-04-08 時点で `Done`
- `A3-v2#2954`
  - runtime workspace detached 化
  - 2026-04-08 時点で `Done`
- `A3-v2#2960`
  - merge / integration contract の canonical 化
  - 2026-04-08 時点で `Done`
- `A3-v2#2961`
  - sibling child serialization
  - 2026-04-08 時点で `Done`
- `A3-v2#3103`
  - backend bootstrap の残件
- `A3-v2#3160`
  - root compatibility 資産の retire / archive / keep 判断
  - 2026-04-08 時点で `Backlog`
- `A3-v2#3119`
  - parent status drift と legacy comment leakage の一次受け
  - 2026-04-08 時点で `Done`
- `A3-v2#3150`
  - verification 前 remediation 順序修正
  - 2026-04-08 時点で `Done`
- `A3-v2#3151`
  - fresh rerun 中の parent-child topology 保持
  - 2026-04-08 時点で `Done`
- `A3-v2#3159`
  - parent canary 中の repeated workspace-local Maven bootstrap 縮減
  - 2026-04-08 時点で `Done`

完了済み:

- `A3-v2#3142`
  - `show-run` / `show-blocked-diagnosis` / watch-summary を束ねる operator log/watch surface は完了済み
- `A3-v2#3144`
  - worker-generated changes の allowlist publication への切り替えは完了済み

重複作成メモ:

- `A3-v2#3032`
  - duplicate
  - 正本は `A3-v2#3031`

次はここでは管理しない。

- `A3-v2#2966`
  - worker invocation の stdin bundle 標準化は完了済み
- worker invocation の全面 redesign
- Git/worktree backend の本格運用改善
- 案件固有 integration の個別論点
  - worker は変更生成だけを担当し、publication/commit は runner が担う
  - runner publication は `git add -A` を使わず、worker response の `changed_files` allowlist だけを stage する
  - allowlist 外の差分が残った場合は publish せず blocked にする

### 0.4.1 2026-04-08 脱v1を含む実行計画 (historical)

この節は 2026-04-08 時点の移行計画を残す historical note である。2026-04-11 時点では `a3-v2/` source tree と legacy automation scripts は削除済みであり、current operator surface は `A3` / `A3Engine` 名へ寄っている。

Portal fresh canary の intake と stabilisation は `A3-v2#3031` / `#3119` / `#3150` / `#3151` / `#3159` を `Done` にしたことで一段落した。以後の主題は `Portal canary を通すこと` ではなく、`A3-v2 が v1/legacy に依存せず自立すること` へ移る。

2026-04-08 時点で、A3-v2 Project で issue 管理されている主残件は `A3-v2#3103` と `A3-v2#3160` である。`A3-v2#2949` / `#2954` / `#2960` / `#2961` は fresh-5 canary と Ruby migration 後の current evidence をもって `Done` 化済みである。`#3103` は backend bootstrap の別レーン、`#3160` は compatibility 資産の retire / archive / keep 判断を担う。

次の計画は、`Portal scheduler の安定化` ではなく `A3-v2 が v1/legacy に依存せず自立すること` を先頭に置いて組み直す。2026-04-08 時点では、operator surface の入口整理と root local utility の Ruby migration は完了したため、次段は backlog / compatibility / 削除判断に移る。

1. 完了済みの前提
- operator surface の入口整理
  - root-managed kanban bridge の `a3-engine` 依存を外した
  - legacy `task a3:portal:*` / `task a3:portal-dev:*` と root local utility の役割を整理した
  - docs / runbook / launcher config の案内を、`legacy scheduler` ではなく A3 正規入口へ寄せた
- root local utility の Python 依存棚卸し
  - `scripts/a3/*.py` を移植対象 / retain / retire に分類し、operator surface を先に固定した
  - `run.py` を含む legacy-v1 backend 中継面は `run.rb` または fail-fast に置き換えた
- Python -> Ruby migration
  - `portal_v2_watch_summary`, `portal_v2_scheduler_launcher`, `assert-live-write`, `portal_v2_verification`
  - `diagnostics`, `reconcile`, `rerun_readiness`, `rerun_quarantine`, `cleanup`
  - retired direct repo source bootstrap, `bootstrap_portal_dev_repos`
  - `stdin bundle worker`, `direct canary worker`, `run.rb` 相当の local utility surface
  - この結果、generic operator 用の `scripts/a3` 直下 Python script は retire 済み。Portal runtime 診断 helper は project-injected glue として残す

2. A3-v2 task relation と backlog の脱A3Engine
- `A3-v2#2949` / `#2954` / `#2960` / `#2961` の description と relation から、`A3Engine` blocker を完了条件として参照する構造を外す
- close 条件を A3-v2 だけで観測できる evidence に言い換える
- `A3Engine` は設計参照にだけ残し、進捗管理の依存先にはしない
- `#2954` / `#2960` / `#2961` を fresh-5 canary と Ruby migration 後の current evidence で close judgment 済み
- 親 `#2949` も同じ evidence で close 済み
- `#3103` は採用 backend が必要なら進め、不要なら close / archive 判断する
- `#3160` で compatibility 資産の inventory と削除可否を確定する

3. Kanboard baseline の収束
- direct / scheduler の parent-child canary は `Portal#3170/#3171/#3172` と `Portal#3173/#3174/#3175` で確認済み
- pause/resume canary は `Portal#3179` で完了し、pause 中に current shot は next task へ進まず、resume 後に child / parent が `Done` まで再開することを確認した
- stale recovery / reconcile canary は `Portal#3180` で完了し、shot kill / active run stale 化後に `show-state` が `stale_shot_lock,stale_run` を露出し、`repair-runs --apply` と clean rerun で `Done` まで復旧できることを確認した
- `A3-v2#3103` の Redmine backend 着手は、この baseline が揃うまで defer する
- phase model の見直しも baseline 完了後に行う。特に `review` と `verification` を別 phase に保つ意味が薄いかを、運用証跡に基づいて再評価する

4. 削除判断
- root-managed kanban bridge と operator surface が `a3-engine` なしで動く
- 現役 operator command が Ruby CLI へ移行し、`scripts/a3` 直下の Python script が不要物だけになる
- legacy automation 用の運用入口が現役導線から外れる
- docs / runbook が legacy を参考情報としてのみ扱い、正規導線として案内しなくなる
- この 4 条件を満たした時点で、`legacy automation scripts` と `A3Engine-v1` の実削除可否を判断する

5. `A3Engine` repo 再作成と naming cutover
- `Kanboard baseline` が未完了の間は、legacy automation scripts と `A3Engine-v1` は参照用にだけ残し、物理削除や repo wipe には進まない
- baseline exit 条件は `Portal#3179` を含む pause/resume canary 完了と stale recovery / reconcile canary 完了である
- baseline 完了後は、現行 `a3-engine` を `a3-engine-legacy` として退避し、そのうえで当時の A3-v2 を新しい `A3Engine` repo として入れ直す
- この cutover 以後は `v2` という呼称を廃止し、runtime / docs / kanban / operator surface では単に `A3` または `A3Engine` と呼ぶ
- 旧 `A3Engine-v1` は新 repo への切替後に archive または削除対象とし、進捗管理の blocker や正規参照先には使わない
- ただし、設計判断の根拠として必要な最小限の文書だけは cutover 前に別保管し、repo 履歴喪失で参照不能にならないようにする
- repo wipe を一度に行うのではなく、`a3-engine -> a3-engine-legacy` の退避、当時の A3-v2 からの新 `a3-engine` seed、`v2` 呼称除去、`a3-engine-legacy` の archive / 削除判断を段階的に進める

6. rename / cutover inventory
- repo / directory 名
  - `a3-engine`
  - `a3-v2`
- path / storage 名
  - `.work/a3-v2/*`
  - `scripts/a3/config/*` に埋め込まれた `a3-v2` surface
  - launchd job / plist 名に含まれる `a3-v2`
- docs / kanban / operator 文言
  - `A3-v2` project 名、issue title、runbook、ledger、design docs
  - `v2` を前提にした phase / canary / cutover の説明
- runtime / bootstrap surface
  - `a3-v2/bin/a3`
  - root Taskfile の `a3:portal-v2:*`
  - manifest / launcher config に残る `v2` 固有 name
- cutover 実施時は、この inventory をもとに repo reset, path rename, docs rename, operator entrypoint 更新を 1 つの移行計画として扱う

7. `a3-v2/` directory retirement task
- 2026-04-11 時点では current 実行経路は `a3-engine` 側へ寄っており、`a3-v2/` は実行上の必須資産ではなく履歴参照資産として扱う
- 実行順は任意だが、`a3-v2/` を物理削除する前に次を漏れなく棚卸しする
- current operator surface 確認
  - root `Taskfile.yml` に `a3:portal-v2:*` など旧実行入口が残っていないこと
  - `scripts/a3/config/*` に `a3-v2/bin/a3` / `a3-v2/lib` を current command として参照する設定が残っていないこと
  - `scripts/a3/*` に残る `portal_v2_*` / `a3_v2_*` helper が current runtime で呼ばれていないこと
  - launchd plist / scheduler package / operator runbook に `portal-v2` / `a3-v2` の current 起動導線が残っていないこと
- tracked file cleanup
  - root repo で tracked な `a3-v2/` 配下を削除対象にする
  - `.agents/skills/a3-v2-checkpoint-review` を削除するか、current `a3-engine` 向け skill へ改名して参照先を更新する
  - `docs/10-ops/10-04-a3-cutover-decision-ledger.md` の `a3-v2` 絶対 path / historical evidence 参照を、削除後も読める形へ移すか historical removed note に置き換える
  - `a3-v2/docs/*` のうち current 設計判断に必要な最小限だけを `a3-engine/docs` または root docs へ移し、それ以外は履歴として git history に委ねる
  - `a3-v2/spec/*` / `a3-v2/lib/*` / `a3-v2/bin/a3` は current implementation source としては維持しない
- workspace / generated cleanup
  - `.work/a3-v2/*` は runtime state ではなく旧 workspace artifact として削除対象にする
  - `/tmp` や launchd working directory に残る `portal-v2` / `a3-v2` 一時ファイル、lock、log があれば cleanup 対象にする
  - disk cleanup 効果は主に `.work/a3-v2/*` 側にあるため、tracked `a3-v2/` 削除だけで容量回復を期待しない
- naming cleanup
  - Kanban activity comment / docs / runbook / operator output で current A3 を `A3-v2` と呼ばない
  - current A3 は `A3` または `A3Engine` と呼び、必要な場合だけ historical label として `A3-v2` を明示する
  - `a3-v2-comment` のような一時ファイル prefix も current code には残さない
- verification
  - `rg "a3-v2|A3-v2|portal-v2"` を実行し、残存が historical note / archived evidence / deleted reference のいずれかに分類済みであること
  - `task a3:portal:describe-state` / `task a3:portal:watch-summary` など current operator command が `a3-v2/` なしで動くこと
  - `a3-engine` focused spec と root project config tests が、`a3-v2/` 削除後も通ること
- 完了条件
  - current 実行経路から `a3-v2/` への依存が 0 件である
  - `a3-v2/` 削除後に参照切れとなる docs / skill / runbook が残っていない
  - `v2` 呼称が current A3 の正規名称として表示されない
  - 削除判断と検証結果を commit message または plan note に残す

要するに、`legacy/v1 を削除するか` の判断と `A3Engine を新 repo として作り直すか` の判断は切り離さず、Kanboard baseline 完了後に `A3-v2 -> A3Engine` への naming cutover まで含めて一体で進める。

要するに、次の実装優先順位は `Python utility の Ruby migration` ではなく、Kanboard baseline を閉じてから `A3-v2#3103` を再開できるかを判断し、そのうえで `legacy/compatibility 資産の削減判断` を進めることである。

### 0.4.2 2026-04-06 Topology / Rerun 設計見直し

Portal fresh rerun (`Portal#3140` / `Portal#3141`) で、A3-v2 internal storage の parent/child topology が脱落し、親が子完了前に `review -> verification` へ進んだ。これは個別不具合というより、external task sync と runnable gate の設計前提がずれていることを示している。

- 実装事実
  - [kanban_cli_task_source.rb](/Users/takuma/workspace/mypage-prototype/a3-v2/lib/a3/infra/kanban_cli_task_source.rb) は、読み込んだ snapshot 集合だけから `child_refs_by_parent` を組み立てる
  - Portal scheduler launcher は `--kanban-status To do` を固定で渡している
  - [sync_external_tasks.rb](/Users/takuma/workspace/mypage-prototype/a3-v2/lib/a3/application/sync_external_tasks.rb) は active task について imported task と existing task を reconcile するが、import 側 topology が欠けていると fresh rerun 中の parent/child graph を正しく再構成できない
  - [runnable_task_assessment.rb](/Users/takuma/workspace/mypage-prototype/a3-v2/lib/a3/domain/runnable_task_assessment.rb) の parent gate は `task.child_refs` を唯一の根拠としている
- 判断
  - `status filter 済み snapshot から topology を導出する` 設計は unsafe
  - topology の正本は `To do` snapshot ではなく、status に依存しない relation graph でなければならない
  - parent phase gate は「現在 runnable な child」ではなく「関係上ぶら下がる child の terminal 状態」を見なければならない
- 設計見直し方針
  - external task source は `selection snapshot` と `topology snapshot` を分離する
  - scheduler の候補抽出には `kanban-status To do` を使ってよいが、topology 構築には full relation graph か task-get/relation API 由来の unfiltered 情報を使う
  - sync/reconcile は topology を partial snapshot で上書きしてはいけない。relation graph は `missing` を `empty` と同一視しない contract にする
  - `refresh_missing_task` / `fetch_by_external_task_id` の fallback 経路は topology source にしてはいけない。single-task refresh は task 本体の status / labels / scope だけを更新し、parent/child graph は別の topology 正本からだけ復元する
  - topology 正本を別 storage に持たない間は、single-task refresh が parent/child 情報を欠く場合でも existing topology を破棄しない
  - parent task の `review` / `verification` / `merge` 進行判定は、保存済み topology と child status を使って gate する
  - fresh rerun regression test は「child が `In review` の間、親は `Inspection` へ進めない」を system-level に確認する

この見直しは `A3-v2#3151` を親 task とし、場当たり修正ではなく `task source -> sync -> runnable gate -> publish` の順でまとめて直す。
- `A3-v2#2961`
  - sibling child serialization
- `A3-v2#3103`
  - Redmine backend bootstrap 設計
- `A3-v2#3119`
  - parent status drift と legacy comment leakage の切り分け
- `A3-v2#3150`
  - verification gate 前の remediation timing / scope 固定

完成に向けた進め方は、次の 5 段階に固定する。

1. fresh rerun の正当性を回復する
- `A3-v2#3151` を最優先で進め、fresh rerun でも topology が落ちないことを固定する
- parent task は child 完了前に review / verification / merge へ進めないことを regression test で確認する
- parent status drift と legacy comment leakage は `A3-v2#3119` で切り分け、A3-v2 実行中に legacy publish が混入しないことを確認する
- formatting-only drift で verification が blocked になり続ける経路は `A3-v2#3150` で止め、runner remediation と gate 実行順を固定する

2. Portal scheduler 実運用導線の確定
- `trigger:auto-implement` / `trigger:auto-parent` だけで A3-v2 scheduler が動く状態を維持する
- scheduler 専用 trigger や検証用 selection 概念は持ち込まない
- workspace root の Python thin tooling は暫定としつつ、運用入口は A3-v2 scheduler に一本化する
- この段階では Portal scheduler が呼ぶ worker を、v1 合意済みの stdin 利用経路へ差し替える
- `stdin bundle` の名前で `codex exec --json -` を呼ぶ thin worker は採用しない
- worker は commit せず、`changed_files` allowlist を返す
- runner は allowlist に含まれた path だけを stage / commit し、publish の canonical owner とする
- この段階の主 task は `A3-v2#3031`

3. Portal fresh canary で自動実行の再検証
- fresh Portal task を使い、A3-v2 scheduler で `To do -> Done` を再度確認する
- 検証対象はまず cross-repo parent/child canary を優先する
- ここで残る gap は `A3-v2#3031` に集約し、product-side と project-side に分類する
- `A3-v2#3151` / `#3119` / `#3150` の fresh evidence はここへ集約し、個別 residual を閉じる材料とする

4. worktree / merge / serialize の残差を close する
- `A3-v2#2954`, `A3-v2#2960`, `A3-v2#2961` は direct verification で大部分を確認済みだが、close には acceptance と relation の最終証跡が必要
- Portal 自動実行の fresh evidence を使って、runtime detached / canonical integration record / sibling child serialize の完了証跡を補強する
- 子 task の証跡が揃ったら、親 `A3-v2#2949` の relation / blocker も整理する

5. operator / deployment 仕上げ
- `A3-v2#3103` を起点に、Kanban backend bootstrap を整理する
- Portal 向け Python thin tooling の Ruby migration は、scheduler launcher / watch-summary を優先対象として別 residual として進める
- `A3-v2#3142` で整えた run evidence 正本の watch/log surface を維持し、以後の residual はそこへ寄せる
- cleanup / retention policy は operator command として残し、Portal 実運用で disk pressure を避ける

この計画では、先に `A3-v2#3151` / `#3119` / `#3150` で fresh rerun と verification gate の正当性を回復し、その後の fresh Portal canary evidence を使って `2954` / `2960` / `2961` / `2949` を閉じる。設計残差を chat 上の印象で閉じず、Portal fresh canary の evidence で closing judgment を行うことを原則とする。

### 0.4.3 2026-04-07 v1 parity gap の固定

Portal scheduler の live 運用で露出した問題は、A3-v2 固有の新規不具合だけではない。legacy A3 (v1) で過去に指摘され、運用改善として取り込まれていた性質が、v2 再実装時に十分継承されず後退していた。

この節では、`v1 では解決済み / v2 で再度失われた` 項目を明示し、以後は「新機能追加」と同列に扱わず parity 回復対象として管理する。

- scheduler shot の非同期分離
  - legacy scheduler では detached shot launch を使い、scheduler 自身は shot 実行を待たなかった
  - current Portal scheduler launcher は detached shot を起動し、shot 本体は `execute-until-idle` を別 process で実行している
  - 2026-04-08 時点で shot 分離自体は parity 回復済み。compatibility launcher config は legacy scheduler を再起動させない fail-fast sentinel とし、残差は他の root local utility の脱v1へ移っている
- stale run reconcile と active run repair
  - root utility は [reconcile.rb](/Users/takuma/workspace/mypage-prototype/scripts/a3/reconcile.rb) で live process / worker run / active run の不整合を検出し、`--apply` で修復できる
  - v2 には同等の operator surface が未整備で、stale blocked / stale active の復旧が場当たりになりやすい
- run-once 前後の safety rail
  - v1 の `execute-run-once` は stale run reconcile、explicit rerun 準備、touched runtime workspace cleanup を前後に挟んでいた
  - v2 の `execute-until-idle` は core loop を直に呼んでおり、この保全レイヤをまだ持っていない
- describe-state 相当の統合観測
  - root utility は [diagnostics.rb](/Users/takuma/workspace/mypage-prototype/scripts/a3/diagnostics.rb) で live process / running_runs / recent_runs / scheduler files / latest results を一度に見られる
  - v2 の `show-scheduler-state` は pause 状態中心で、live shot failure や stale process の把握に必要な粒度が不足している
- watch-summary の live observability
  - v1 は worker run/log ベースで live 実行状況を追えた
  - v2 の watch-summary は storage-first で始まったため、launchd failure / current command / heartbeat / worker log 導線が一度失われた
  - 2026-04-07 時点で launchd failure overlay は戻したが、v1 同等の live observability には未達
- launchd env の runtime completeness
  - v1 は launcher config / shell env file から Kanban 接続情報を取り込んでいた
  - v2 は初期状態で `KANBOARD_API_TOKEN` / `KANBOARD_BASE_URL` を launchd env file へ出しておらず、常駐 scheduler が起動直後に落ちる後退が発生した
- build / gate lane の分離
  - v1 は少なくとも `build` と `gate` の 2 lane で 1 本ずつ進行でき、gate 実行中でも別 lane の build candidate を流せた
  - v2 は [execute_next_runnable_task.rb](/Users/takuma/workspace/mypage-prototype/a3-v2/lib/a3/application/execute_next_runnable_task.rb) が `next runnable` を 1 件選び、その phase 実行を同期で待つため、実質 single-lane になっている
  - その結果、`Portal#2982` が `verification` 実行中の間、`Portal#2987` は runnable 候補でも着手されず待機した
- cleanup / quarantine の deterministic 契約
  - root utility は [cleanup.rb](/Users/takuma/workspace/mypage-prototype/scripts/a3/cleanup.rb) で issue/runtime/results/logs の cleanup 分類を持つ
  - v2 は terminal cleanup command を持つが、registered worktree removal と plain-copy quarantine の責務分離が未完成で、`repo-beta` の registered worktree 残存や `repo-alpha` plain directory 残骸が出た

判断:

- v2 の残差は「実装中だから粗い」ではなく、「v1 で獲得した運用知見の継承漏れ」が含まれている
- 以後の Portal scheduler 改修は、個別 bug fix の列挙ではなく `v1 parity gap` の回収として優先順位を付ける
- 特に次の 4 点は parity 回復の最優先とする
  - scheduler shot の非同期分離
  - build / gate lane 分離の復元
  - stale run reconcile / describe-state の operator surface 回復
  - cleanup / quarantine の deterministic contract 完了

完了条件:

- detached shot 起動が v2 に存在し、launchd scheduler は shot 完了待ちをしない
- build lane と gate lane が独立に 1 本ずつ進行でき、gate 実行中の task が build candidate を不必要に塞がない
- stale active / stale blocked を operator が 1 コマンドで診断・修復できる
- watch-summary / state inspection で launch failure, live run, stale run, queued To do を混同せず表示できる
- terminal task 後に registered worktree が product repo に残らず、quarantine は plain copy のみになる

### 0.4.4 2026-04-07 v1 / v2 parity audit と回復計画

Portal scheduler の v2 は、単一の bug を潰せば済む段階ではない。`v1 で運用要件として成立していたもの` と `v2 で未実装・再劣化したもの` を真正面から比較し、parity backlog として回収する。

#### 0.4.4.1 監査結果

| 項目 | v1 | v2 現状 | 観測済みの症状 | 回復方針 |
| --- | --- | --- | --- | --- |
| scheduler shot 分離 | legacy scheduler は detached shot を起動し、自身は待たない | current Portal scheduler launcher が detached shot を起動し、shot 本体で `execute-until-idle` を実行する | current behavior は改善済み。compatibility launcher config は fail-fast sentinel にし、active shot は current launcher/process だけを参照先として扱う | launchd scheduler は detached shot だけ起動し、shot 完了待ちをしない |
| lane model | `build` / `gate` で少なくとも 1 本ずつ進行できる | lane 概念が無く、[execute_next_runnable_task.rb](/Users/takuma/workspace/mypage-prototype/a3-v2/lib/a3/application/execute_next_runnable_task.rb) が runnable 1 件を同期実行 | `Portal#2982` verification 中に `Portal#2987` が着手されない | lane-aware selection と lane ごとの shot 分離を入れる |
| pause semantics | 新規 shot 停止に加え、current cycle が次 task に入る前にも効く | pause は state flag を立てるだけで、起動済み `execute-until-idle` は次 task に進みうる | pause 後も `2986/2987` が進んだ | cycle ごとに `paused?` を再確認し、current execution 後は `stop_reason=paused` で抜ける |
| stale run repair | [reconcile.rb](/Users/takuma/workspace/mypage-prototype/scripts/a3/reconcile.rb) が active run / worker run / live process を突き合わせ、`--apply` で修復 | 同等 surface が未整備 | stale blocked / stale active を手動 cleanup で都度対処 | `show-state` + `repair-runs` 相当の operator command を戻す |
| describe-state / observability | [diagnostics.rb](/Users/takuma/workspace/mypage-prototype/scripts/a3/diagnostics.rb) が running/recent/scheduler/result を一括表示 | `show-scheduler-state` は pause 中心、watch-summary は storage-first | launchd failure が `idle` に見える、live process と storage state がずれる | `show-state` を v1 相当へ拡張し、watch-summary は state inspection の表層にする |
| watch-summary の live 性 | worker run / current command / live process を見せる | storage の `tasks/runs` 中心。overlay を後付けで追加中 | stale status に引きずられやすい | watch-summary の正本を `state inspection + storage` の合成に寄せる |
| launchd env completeness | launcher config から Kanban 接続情報を env file へ出す | 初期実装で `KANBOARD_*` を出していなかった | scheduler が `KANBOARD_API_TOKEN is required` で即死 | env completeness を runtime contract として spec 化し、prepare script を正本化する |
| merge publish モデル | operator が見る root repo と live branch の整合を崩しにくい運用 surface | merge は temporary branch 化したが、publish はまだ `update-ref` ベース | `member-portal-starters` で `feature/prototype` が進んだのに staged diff が残る | live branch 反映も checkout-based publish へ寄せ、root repo dirty を構造的に防ぐ |
| terminal cleanup | [cleanup.rb](/Users/takuma/workspace/mypage-prototype/scripts/a3/cleanup.rb) が issue/runtime/results/logs を分類 | registered worktree removal と quarantine plain copy の責務が未分離 | `repo-beta` registered worktree 残存、`repo-alpha` plain dir 残骸 | cleanup contract を 6.2.1 の計画どおり本実装する |

#### 0.4.4.2 現時点の blocker 分類

- P0: scheduler 実行モデル
  - shot 非同期分離
  - build / gate lane 復元
  - pause semantics 修正
- P1: operator observability / repair
  - describe-state parity
  - stale run repair
  - watch-summary の live state 正本化
- P1: merge / publish 契約
  - live branch publish の checkout-based 化
  - root repo dirty 再発防止
- P2: cleanup / quarantine
  - terminal worktree cleanup の deterministic 化

#### 0.4.4.2.1 安定化フェーズの運用ルール

Portal live canary は、以後 `新機能実験` ではなく `安定化フェーズ` として扱う。個別 bug を見つけて都度直すのではなく、P0/P1 の受け入れ条件を満たすまで「scheduler として信頼できる」とは扱わない。

固定 rule:

- P0 が揃うまでは、新しい lane や project 固有機能を追加しない
- canary で新しい failure mode が出た場合、次の canary を流す前に regression test を追加する
- `blocked` / `idle` / `running` / `stale` の判定は operator surface を正本とし、個別 log 読みの場当たり判断に戻らない
- product task の進行と A3-v2 基盤改修を同じ成功指標で混ぜない
- `Done` になった canary task があっても、P0 acceptance を満たさなければ A3-v2 の品質安定とは判定しない

#### 0.4.4.2.2 P0 受け入れ条件

P0 は「scheduler が最低限壊れず、operator が状態を復旧できる」ラインである。

- shot/runner separation
  - launchd / `run-once` は detached shot を起動して即戻る
  - active shot が存在する間、新規 shot は single-flight で抑止される
  - stale shot は `show-state` と `repair-runs` で診断・修復できる
- lane model
  - `build` と `gate` が 1 本ずつ独立に進行できる
  - gate 実行中でも build candidate が不必要に塞がれない
  - parent review は `gate` lane へ正しく分類される
- pause semantics
  - pause 後、新規 shot は起動されない
  - current shot は current task 完了後に次 task へ進まない
  - resume 後は次 tick で再開できる
- Kanban import / task selection
  - `To do` task が storage へ再現可能に import される
  - `blocked label` と `status` の解釈が operator に観測可能である
  - parent/child topology が import 時に欠落しない
- worker / launcher contract
  - task packet に title / description / labels / parent_ref / child_refs / acceptance criteria が入る
  - phase ごとの model selection は launcher config 正本から解決される
  - CLI 不整合は fail-close し、silent fallback を持たない
- publish contract
  - implementation worker の actual diff が canonical changed_files と一致する
  - merge/publish 後に live repo が clean である
  - rerun 前の task branch tip は archive ref に退避される

#### 0.4.4.2.3 P1 受け入れ条件

P1 は「運用者が live で詰まっても自力で観測・修復できる」ラインである。

- `show-state`
  - launchd / lane lock / active shot / active worker / queued task / blocked task を 1 回で表示できる
- `repair-runs`
  - stale shot / stale run / stale task state を dry-run と `--apply` で修復できる
- watch-summary
  - `show-state` に従属し、launch failure と idle を混同しない
  - queued `To do` と blocked task を storage 欠損で見失わない
- cleanup / quarantine
  - terminal task 後に registered worktree を残さない
  - quarantine は plain copy のみ
  - cleanup failure は repairable state として露出する

#### 0.4.4.2.4 canary exit criteria

安定化フェーズを抜ける条件は、単一の成功 task ではなく、次の acceptance canary 群を連続で通すことで判定する。

- single-task canary
  - implementation -> verification -> merge が 1 本通る
  - live repo dirty が残らない
- parent/child canary
  - child implementation と parent review が topology を保って進む
  - child 完了後に parent が正しく gate lane へ入る
- pause/resume canary
  - pause 中に新規 shot が起動しない
  - current shot は next task へ進まず停止する
  - resume 後に再開する
- stale recovery canary
  - shot kill / worker kill 後に `repair-runs --apply` で復旧できる
  - Kanban と storage が再整合する

exit rule:

- 上の 4 canary が連続で成功すること
- 各 canary の failure mode が regression test 化されていること
- operator が manual filesystem cleanup なしで復旧できること
- `Portal` canary を 1 本成功させた、だけでは exit と見なさない

#### 0.4.4.3 実装順

1. scheduler shot / pause / lane の parity 回復
   - current shot が次 task に入る前の pause 再確認
   - detached shot 起動
   - build/gate lane 選定
2. operator repair surface の回復
   - `show-state`
   - `repair-runs`
   - watch-summary の data source 見直し
3. merge publish の一本化
   - prepare / publish を checkout-based publish まで含めて完了させる
   - single / parent-child の両経路で live repo が clean になる spec を持つ
4. cleanup contract 実装
   - registered worktree removal
   - quarantine plain copy
   - retention 分類

#### 0.4.4.4 回復アーキテクチャ

v1 parity gap の回収は、個別 bug を都度潰すのではなく、Portal scheduler runtime を次の 4 層へ分けて設計し直すことで進める。

1. `tick`
  - launchd / operator command が一定間隔で呼ぶ入口
  - 責務は `shot dispatch` だけであり、phase 実行を待たない
2. `shot`
  - Kanban sync から runnable selection、phase 実行開始までを担う一回分の scheduler cycle
  - lane ごとに single-flight で動く
3. `run`
  - task 単位の phase 実行
  - implementation / review / verification / merge の canonical owner
4. `operator surface`
  - `show-state` / `repair-runs` / `watch-summary`
  - storage、live process、launchd、worker evidence を合成して見せる

この分離により、tick の寿命、shot の寿命、task run の寿命を意図的に切り離す。

##### 0.4.4.4.1 tick / shot 分離

- launchd が起動するのは `dispatcher` だけとする
- dispatcher は各 lane の active shot lock を確認し、空いている lane にだけ detached shot を起動して即終了する
- shot は `execute-until-idle` を直接長時間回し続けるのではなく、`single lane / bounded cycle` の 1 回実行に限定する
- tick と shot の通信は storage と lock file だけを使い、親子 process の待ち合わせを持たない
- これにより
  - launchd job は long-running process にならない
  - stale shot が次周期を物理的に塞ぐのを避けられる
  - pause は「次の shot を出さない」と「current shot が次 task に入らない」を分けて扱える

固定 contract:

- `dispatcher`
  - detached 起動のみ
  - task 選定をしない
- `shot`
  - active lock を握った lane だけで 1 task ずつ進める
  - current task 完了後に `paused?` を再確認し、次 task に進むかを決める
- `run`
  - task / phase ごとの evidence を残す

##### 0.4.4.4.2 lane model

lane は v1 parity と現在の phase model を両立する最小構成に固定する。

- `build`
  - `implementation`
- `gate`
  - `review`
  - `verification`
  - `merge`

判定 rule:

- task の current phase から lane を一意に決める
- parent review は `phase=review` だが `gate` lane に属する
- 同一 lane では single-flight とし、同時に複数 task を走らせない
- lane が違えば同時に 1 本ずつ進行できる

selection rule:

- `build` lane は implementation runnable のみを見る
- `gate` lane は review / verification / merge runnable のみを見る
- task source sync は lane 非依存で 1 度だけ行い、その snapshot から各 lane が自分の候補を選ぶ
- parent gate は topology 正本と child terminal 状態で判定し、partial status snapshot から child_refs を再構成しない

非目標:

- lane 数を 2 より増やすこと
- task ごとに lane を外部指定すること
- build / gate 以外の project 固有 lane 名を A3 本体へ持ち込むこと

##### 0.4.4.4.3 operator state model

`show-state` を operator 正本にする。watch-summary は `show-state` の表層表示とし、独自に storage だけを読む経路を正本にしない。

`show-state` が合成する入力:

- persisted task / run / evidence storage
- live shot process
- live worker process
- launchd status / last exit
- scheduler pause flag
- active lane lock

出力の最小 shape:

- `scheduler`
  - paused
  - next_tick_source
  - launchd_status
  - last_exit
- `lanes`
  - lane 名
  - active_shot_pid
  - active_task_ref
  - stale 判定
- `running_runs`
  - task_ref
  - phase
  - lane
  - heartbeat
  - current_command
- `queued_tasks`
  - lane ごとの next candidates
- `repairable`
  - stale shot
  - stale run
  - inconsistent storage

これにより、`idle` / `running` / `failed` / `stale` / `paused` を同じ surface で区別する。

##### 0.4.4.4.4 repair-runs contract

`repair-runs` は v1 `reconcile.rb --apply` の後継として、次の 3 つだけを canonical に扱う。

1. stale shot
  - lane lock は残るが live pid がいない
2. stale run
  - run は active だが worker process がいない
3. stale task state
  - task storage が `in_progress` / `blocked` のまま、run と process が整合しない

修復 rule:

- task を勝手に `Done` にしない
- terminal 判定は evidence と run outcome がある場合に限る
- task status reset は Kanban 正本への explicit transition としてだけ行う
- `repair-runs` は dry-run を既定とし、`--apply` でだけ storage / Kanban を変更する

禁止:

- process 不在を理由に task を暗黙 `To do` へ戻す fallback
- watch-summary 側だけで stale を吸収して正本 state を濁すこと

##### 0.4.4.4.5 merge / publish parity

merge は `prepare` と `publish` を分けるが、publish 完了条件は `target ref が進んだ` では足りない。

publish 完了条件:

- target branch ref が merged head を指す
- canonical live checkout がその merged head を見ている
- `HEAD / index / working tree` が一致している
- task 用一時 ref と一時 workspace の cleanup が完了している

single task と parent/child finalize は同じ publish contract に従う。`single だけ update-ref 経路を残す` のような分岐は持たない。

##### 0.4.4.4.6 cleanup / quarantine parity

cleanup は「registered worktree を source repo から外す責務」と「調査用 quarantine を plain copy で残す責務」を分ける。

固定 rule:

- terminal task の cleanup 完了時に、product repo 側へ registered worktree を残さない
- quarantine は Git metadata を持たない plain copy だけを残す
- blocked diagnosis / evidence / logs は workspace cleanup と独立した retention を持つ
- cleanup failure は `completed` と見なさず、operator surface に repairable として出す

#### 0.4.4.5 回復の実装単位

設計から実装へ落とす最小単位は次に固定する。

1. `dispatcher` / `shot` / `lane lock`
2. lane-aware runnable selection
3. `show-state`
4. `repair-runs`
5. watch-summary の `show-state` 従属化
6. checkout-based publish completion
7. deterministic cleanup / quarantine

各単位は、対応する parity gap を 1 対 1 で回収するように進める。複数項目を曖昧に跨ぐ修正は acceptance を弱くするので避ける。

#### 0.4.4.6 実装順と gate

安定化フェーズの実装順は次に固定する。

1. `show-state` / `repair-runs`
2. shot/runner separation と single-flight
3. lane-aware selection と pause semantics
4. Kanban import / task packet / launcher contract の acceptance 固定
5. publish contract の clean completion
6. cleanup / quarantine

各 step の gate:

- 設計を `60` に固定する
- checkpoint review で fallback / escape hatch / domain 汚染が無いことを確認する
- unit / integration / acceptance の 3 層で最低 1 本ずつ test を追加する
- live canary は直前 step が green のときだけ回す

禁止:

- regression test なしで canary failure を「既知」として先送りすること
- P0 未達のまま model tuning や project 固有最適化へ進むこと
- operator surface 未整備のまま cleanup や rerun を manual shell 操作へ戻すこと

### 0.4.5 Kanban backend cutover plan

2026-04-10 時点で、A3 Engine の historical kanban backend baseline は `Kanboard` だった。`Portal` 上の Kanboard baseline canary は `Portal#3170/#3171/#3172`, `Portal#3173/#3174/#3175`, `Portal#3179`, `Portal#3180` で完了しており、backend 非依存 contract の過去証跡として文書に保持する。2026-04-12 の判断で current runtime の Kanboard compatibility path は削除し、`task kanban:*` と `a3-engine/tools/kanban/kanban_cli.py` は SoloBoard 専用に固定する。

Kanboard baseline の current evidence:

- direct canary
  - `Portal#3170/#3171/#3172` で parent/child topology を保って `Done` まで完走した
- scheduler canary
  - `Portal#3173/#3174/#3175` で scheduler 経路の child -> parent handoff を保って `Done` まで完走した
- scheduler hygiene
  - `scheduler-shot.lock` の stale cleanup 不具合を修正し、正常終了後に `show-state` が `shot status=none` を返すことを確認した
- pause/resume canary
  - `Portal#3179` で pause / resume 後の child -> parent handoff を含めて `Done` まで完走した
- stale recovery / reconcile canary
  - `Portal#3180` で shot kill / stale run 露出 / `repair-runs --apply` / clean rerun を通し、`Done` まで復旧した

したがって、Kanboard baseline は「切替前の完了証跡」として残すが、実行可能な compatibility path は残さない。今後の課題は SoloBoard 専用 runtime の長期運用 hardening と Docker/runtime packaging を固定し、実 Portal source の `repo:both` parent/full verification canary を完成条件として通すことである。

#### 契約

- A3-v2 runtime は backend 名に依存した task/phase rule を持たない
- launcher / runtime が要求するのは、現在の `subprocess-cli` compatibility bridge で実際に踏んでいる次の contract である
  - task selection/import
    - `task-snapshot-list`
    - `task-get`
    - `task-label-list`
  - task status / publish
    - `task-transition`
    - `task-label-add`
    - `task-label-remove`
    - `task-comment-create`
  - topology / follow-up child
    - `task-relation-list`
    - `task-relation-create`
    - `task-create`
    - `label-ensure`
- `Project Surface` は SoloBoard 固有の domain rule を持たず、kanban I/O 差分は launcher/bootstrap/adapter に閉じる
- Redmine backend canary は破棄し、A3 の bundled kanban は SoloBoard 前提に固定する
- current operator surface や launcher contract を揺らさず、SoloBoard 固定化は adapter / bootstrap / Docker packaging の順に閉じ込める

#### 0.4.5.1 SoloBoard 固定化と対応計画

2026-04-12 時点の方針では、A3 の bundled kanban は `SoloBoard` のみとする。判断根拠は、workspace root の `task kanban:api -- ...` と `a3-engine/tools/kanban/kanban_cli.py` が提供する current surface を SoloBoard が満たせることを local spike と isolated canary で確認し、Kanboard compatibility path を残す価値よりも誤操作・保守ノイズのリスクが上回ると判断した点にある。実運用で踏んでいる contract は `task-snapshot-list`, `task-get`, `task-label-list`, `task-transition`, `task-label-add`, `task-label-remove`, `task-comment-create`, `task-relation-list`, `task-relation-create`, `task-create`, `label-ensure` に集中しており、A3 domain rule は SoloBoard の API shape へ直接依存させない。

SoloBoard は `board`, `lane`, `ticket`, `comment`, `label`, `blocker`, `parent/child`, `transition` を持ち、A3 Engine が現在使っている operator surface の主要部分を受け止められる。さらに `GET /api/tickets/{ticketId}/comments`, `GET /api/tickets/{ticketId}/relations`, `PATCH /api/tickets/{ticketId}/transition`, `ref` / `shortRef` が OpenAPI に入っており、A3 adapter で必要だった補助 API も揃い始めている。したがって、今後の主戦場は「kanban backend を増やすこと」ではなく、SoloBoard 固定の compose bundle と bootstrap / doctor / smoke / long-running observation を安定化することである。

対応計画:

- step 1: `task kanban:api -- ...` の current contract を固定し、A3 Engine が実際に使う command/output shape を regression test で保護する
- step 2: `a3-engine/tools/kanban/kanban_cli.py` の SoloBoard adapter 境界を維持し、A3 domain rule が SoloBoard API shape に漏れないことを regression test で保護する
- step 3: `project -> board`, `status -> lane`, `done flag -> isCompleted` を adapter 規約として固定し、canonical ref `Portal#123` を維持する
- step 4: relation は現行利用が濃い `subtask` と blocking 系を優先し、workspace 実使用の薄い relation kind は必要になるまで広げない
- step 5: `Taskfile` / bootstrap / doctor / up/down を SoloBoard runtime に差し替えて canary し、operator surface が維持されることを確認する
- step 5a: bootstrap には board 作成だけでなく、lane 順序整備、tag 初期化、`Portal` / `OIDC` / `A3Engine` board の初期 seed、初回 ticket 作成まで含める
- step 6: Docker/runtime packaging は SoloBoard parity 後に着手し、A3 runtime と kanban backend を同一 compose/runtime bundle として同梱する
- step 7: SoloBoard の Docker runtime を標準起動経路として整理し、`task kanban:up` / `task kanban:down` / `task kanban:logs` / `task kanban:url` がその経路を指すようにする。公開ポート番号は SoloBoard runtime の標準値として固定する
- step 8: bootstrap は SoloBoard board/lane/label 初期化まで含め、既存の `Portal` / `OIDC` / `A3Engine` surface を再現できるようにする
- step 9: isolated canary で single / parent-child が完走した後は、generic operator default を SoloBoard に固定し、Kanboard compatibility path は削除する

2026-04-10 の local spike では、SoloBoard を Docker で `http://127.0.0.1:3460` に起動し、board 作成、lane 初期化、tag 作成、ticket 作成、parent/child 参照、blocker 更新、comment 作成、lane name による transition、detail / relations / comments / ticket list の取得まで確認した。したがって、bootstrap は単なる board seed ではなく「A3 current surface が要求する operator 初期化」を担うものとして設計する。

2026-04-10 の追加実装で、workspace root では次を current progress として確認した。

- `a3-engine/tools/kanban/kanban_cli.py` に backend adapter 境界を入れ、`soloboard` backend で `task-get`, `task-list`, `task-snapshot-list`, `task-comment-list/create`, `task-transition`, `task-label-add/remove`, `task-relation-list/create/delete`, `task-create`, `task-update`, `label-ensure` を実行できる
- `task soloboard:doctor`, `task soloboard:api`, `task soloboard:bootstrap` を追加し、SoloBoard runtime 単体でも operator surface を踏める
- `task soloboard:smoke` を追加し、current kanban compatibility surface を SoloBoard に対して一通り打つ parity smoke を実行できる
- `task kanban:up/down/logs/url/doctor/api/bootstrap:*` は SoloBoard 専用 entrypoint とし、`KANBAN_BACKEND=kanboard` / `kanboard:*` は削除する
- `task a3:portal:cutover:doctor` を追加し、SoloBoard backend で `kanban:doctor -> watch-summary -> describe-state -> kanban:smoke` を一連で観測できるようにした。旧 compatibility path の比較入口は削除する
- `task a3:portal-soloboard:scheduler:run-once`, `task a3:portal-soloboard:watch-summary`, `task a3:portal-soloboard:describe-state`, `task a3:portal-soloboard:scheduler:control` を追加し、current `.work/a3/portal-kanban-scheduler-auto` と衝突しない isolated storage (`.work/a3/portal-soloboard-canary`) で one-shot canary を流せる
- historical evidence として、retired `task a3:portal-soloboard:direct-canary:run-once` で isolated single full-phase canary を流し、`Portal#17` が `implementation -> verification -> merge -> Done` まで完走した
- historical evidence として、retired `task a3:portal-soloboard:parent-child:direct-canary:run-once` と isolated `watch-summary` / `describe-state` で `Portal#18/#19/#20` が `Done` まで完走した。direct canary run entrypoint は後続整理で削除済みである
- isolated canary の no-op 実行では `executed 0 task(s); idle=true stop_reason=idle` を確認し、さらに `plan-next-runnable-task` で SoloBoard 上の labeled `To do` task が `next runnable ... at implementation` と選抜されるところまで確認した
- SoloBoard の mutation 後 read が短時間揺れるため、CLI の `task-label-add` / `task-label-remove` は observation retry を入れて false negative を避ける
- `task kanban:smoke` も `KANBAN_BACKEND=soloboard` で generic 導線から実行できる
- `Portal`, `OIDC`, `A3Engine` の board / lane / tag bootstrap は generic `kanban:bootstrap:*` からも実行できる

2026-04-12 の parity 再確認では、standalone SoloBoard (`http://localhost:3460`) に対して `task soloboard:doctor`, `task soloboard:bootstrap`, `task soloboard:smoke` を実行し、board / lane / tag / ticket / relation / comment / transition surface が維持されていることを確認した。`soloboard:smoke` が作成した `Portal#5/#6` は確認後に `Done` へ transition 済みである。

したがって、step 1 から step 5b と isolated canary の single / parent-child 完走までは確認済みであり、残る main work は「未使用 command contract の parity 確認」「長期 scheduler-loop 運用と read-after-write hardening」「Docker/runtime packaging」「実 Portal source の `repo:both` parent/full verification canary」である。Kanboard compatibility path は削除対象であり、実行入口としては維持しない。

この検討のゴールは「backend を増やすこと」ではなく、「A3 Engine runtime が SoloBoard を bundled kanban として使うときも Project Surface と phase rule を汚染しないこと」を current surface で実証することにある。実装着手時も `Project Surface` と phase rule を SoloBoard 固有都合で汚染しないことを継続条件とする。

#### 0.4.5.1a Docker/runtime packaging freeze inputs

SoloBoard を current generic default に寄せた時点で、Docker/runtime packaging で先に固定すべき入力は次のとおりである。

- bundle contents
  - `a3` container
    - `a3-engine/bin/a3`
    - current preset/config
    - SoloBoard adapter
    - job queue / agent protocol endpoint
  - `soloboard` container
    - board/lane/tag bootstrap を含む current backend
  - project runtime container or host runtime with `a3-agent`
    - project 固有 toolchain (`task`, `mvn`, `java`, `npm` など)
    - project runtime package / project-local helper (`scripts/a3/*` 相当を含む)
    - A3 job protocol の consumer
    - log / exit code / artifact collection
  - shared writable state volume
    - A3 scheduler/runtime state
    - SoloBoard state
    - job result / evidence / runtime logs
- operator entrypoints to preserve
  - `task kanban:*`
  - `task a3:portal:*`
  - `task a3:portal:cutover:doctor`
- removed historical compatibility entrypoints before freeze
  - `KANBAN_BACKEND=kanboard task kanban:*`
  - `kanboard:*`
- freeze acceptance before compose lock
  - isolated single canary が `Done`
  - isolated parent-child canary が `Done`
  - current mainline cutover doctor が SoloBoard default で通る
  - 実 Portal source の `repo:both` parent/full verification canary が通る
  - repeated scheduler-loop 観測で追加 hardening 要否が判断できる
  - local compose bundle (`task a3:portal:bundle:up/bootstrap/doctor/smoke`) が通る

2026-04-11 時点では、workspace root に `docker-compose.a3-portal-soloboard.yml` と `docker/a3-runtime/Dockerfile` を置き、`task a3:portal:bundle:up`, `:doctor`, `:bootstrap`, `:smoke`, `:down`, `:logs` を追加した。2026-04-13 の配布整理で compose 正本は `a3-engine/docker/compose/a3-portal-soloboard.yml`、runtime Dockerfile 正本は `a3-engine/docker/a3-runtime/Dockerfile` へ移動した。local bundle は `a3-runtime` container と `soloboard` container を同一 compose project で起動し、`doctor` で `ruby`, `python3`, `task`, SoloBoard `/api/boards` を確認し、`bootstrap` で `Portal` / `OIDC` / `A3Engine` board/lane/tag surface を seed し、`smoke` で relation/comment/transition を含む compatibility surface を実機確認できる。

ただし、この spike では Portal verification を A3 runtime container 内で直接実行するために Temurin 25 JDK を A3 image へ入れており、これは完成形ではない。完成形では A3 container は汎用 orchestration/control plane とし、project 固有 toolchain は host または project dev-env container に配置した `a3-agent` が引き受ける。したがって次の slice は「A3 image から project runtime を剥がす」「A3 job protocol と `a3-agent` MVP を設計する」「SoloBoard 固定 compose bundle に manual loop agent を接続する」に寄せる。

#### 0.4.5.1b A3 container / SoloBoard / project agent deployment shape

A3 の Docker 配布は single container ではなく、SoloBoard と project runtime agent を含む compose bundle として設計する。SoloBoard は A3 image に内包しない。A3 は SoloBoard API を bundled kanban として利用し、project command 実行は `a3-agent` へ job として委譲する。

```text
+--------------------------------------------------+
| docker compose project                           |
|                                                  |
|  +-------------------+                           |
|  | docker:a3          |                           |
|  | scheduler/state    |                           |
|  | kanban adapter     |                           |
|  | job queue/API      |                           |
|  +----+----------+---+                           |
|       |          |                               |
|       |          | job protocol                  |
|       |          v                               |
|       |   +------+----------------+              |
|       |   | docker:dev-env         |              |
|       |   | a3-agent               |              |
|       |   | project toolchain      |              |
|       |   | task/mvn/java/npm      |              |
|       |   +-----------------------+              |
|       |                                          |
|       | SoloBoard API                            |
|       v                                          |
|  +----+--------------+                           |
|  | docker:soloboard  |                           |
|  | kanban UI/API     |                           |
|  +-------------------+                           |
+--------------------------------------------------+
```

責務境界:

- `docker:a3`
  - A3 engine / scheduler / orchestration / state / job queue / SoloBoard adapter を持つ
  - project 固有の JDK / Maven / Node / DB client / test runner は持たない
  - SoloBoard の board/lane/tag/ticket/comment/label/relation を kanban surface として扱う
- `docker:soloboard`
  - A3 bundled kanban service として compose で同梱する
  - A3 state store ではなく、kanban UI/API として扱う
  - board/lane/tag bootstrap は A3 bundle bootstrap の一部にする
- `a3-agent`
  - host OS、project dev-env container、CI runner のいずれにも配置できる lightweight worker とする
  - A3 job を pull/claim し、配置先 runtime の command を実行する
  - stdout/stderr/exit code/artifact/heartbeat を A3 へ返す
  - policy により workspace / command / env / timeout / artifact path を制限する
  - workspace materialization / dirty check / cleanup は配置先 runtime で実施し、A3 へは workspace descriptor と result evidence を返す

初期協調方式は `agent pull` を第一候補とする。agent が自分の runtime 準備完了後に A3 へ接続し、A3 が保持する job queue から work を取るため、A3 container が agent の起動順や配置先を強く仮定しなくてよい。

```text
docker:a3                       docker:dev-env or host
---------                       ----------------------
poll SoloBoard
plan phase job
enqueue job
                                a3-agent polls next job
                                claim job
                                run project command
                                capture logs/artifacts
                                post result
read result
update A3 state
update SoloBoard
```

`a3-agent` の技術選択は macOS / Linux / WSL2 Ubuntu 向け single binary を優先し、Go を第一候補とする。理由は process execution、signal/cancel、file/HTTP transport、JSON を runtime 依存なしで持てるためである。Windows native は標準対象外とし、Windows 利用時は WSL2 Ubuntu 上で Linux runtime として扱う。A3 本体が Ruby であっても、A3 と agent の境界は JSON job protocol にするため言語差は domain model へ漏れない。

Job protocol の最小 contract:

- `JobRequest`
  - `job_id`
  - `task_ref`
  - `phase`
  - `runtime_profile`
  - `working_dir`
  - `command`
  - `args`
  - `env`
  - `timeout_seconds`
  - `artifact_rules`
- `JobResult`
  - `job_id`
  - `status`
  - `exit_code`
  - `started_at`
  - `finished_at`
  - `summary`
  - `log_uploads`
  - `artifact_uploads`
  - `workspace_descriptor`
  - `heartbeat`

HTTP transport では `JobResult` に host/container local path だけを入れてはならない。agent の filesystem は A3 container から読めるとは限らないため、stdout/stderr/combined log と artifact は A3-managed artifact store へ upload/stream し、`JobResult` には A3 側で解決可能な artifact id / digest / byte size / retention class を返す。大きい artifact を shared volume で扱う場合も、shared volume id と mount contract を runtime profile に明示し、A3 側から読めない local path を evidence に残さない。

transport は次の順で実装する。

1. HTTP pull transport
   - 同一 compose network の `docker:dev-env` agent と自然に接続できる
   - host agent でも `localhost` port publish で利用できる
   - log/artifact は A3 artifact API へ upload/stream する
2. file exchange transport
   - offline / air-gapped / restricted network 向けの fallback
   - atomic write と retention policy を別途定義する
   - shared directory を使う場合も `status.json` は A3 から読める path だけを参照する

この方式により、project runtime は次のどちらにもできる。

- host runtime
  - host に install した `a3-agent` が local `task` / `mvn` / `java` を実行する
- docker dev-env runtime
  - project dev-env image に install した `a3-agent` が container 内の toolchain で実行する

いずれの場合も、A3 は SoloBoard と job result だけを見て phase を進める。project 固有 runtime を A3 image へ bake しないことを配布設計の完了条件に追加する。

workspace materialization の owner は `a3-agent` 側 runtime とする。A3 は source descriptor / repo slot / target ref / isolation requirement を job に含めるが、checkout/worktree 作成、実行前 dirty check、実行後 cleanup、quarantine snapshot 作成は agent が配置された runtime の filesystem で行う。A3 は agent が返す `workspace_descriptor` と artifact/evidence を検証し、phase 開始前の existence guarantee を domain rule として判定する。これにより host runtime と docker dev-env runtime の両方で同じ protocol を使える。

A3 Engine は control plane であり、Docker + host/dev-env agent mode では project repo の filesystem mutation owner ではない。Engine が行ってよいのは `workspace_request` / merge-publish request の作成、agent result の検証、artifact/evidence の記録、task/run state の更新である。project repo に対する worktree 作成、branch checkout、commit、merge、cleanup、quarantine は `a3-agent` が runtime profile の `source_aliases` と `workspace_root` に基づいて実行する。Ruby Engine 側の direct publication / merge implementation は削除済みであり、未設定時は `DisabledWorkspaceChangePublisher` / `DisabledMergeRunner` が fail closed する。`LocalGitWorkspaceBackend` は workspace preparation / cleanup の transitional surface として残るが、project repo mutation の正本にはしない。

`start-run` は run state を開始するだけで project workspace を materialize しない。worker / verification / merge の agent-owned path では phase execution でも Engine workspace preparation を skip し、control-plane trace 用の synthetic workspace だけを使う。project repo の実 worktree は agent job request (`workspace_request` / `merge_request`) を受けた `a3-agent` が作成する。

2026-04-11 時点では、Ruby domain 側の最小 contract として `AgentJobRequest`、`AgentJobResult`、`AgentArtifactUpload`、`AgentWorkspaceDescriptor`、`AgentWorkspaceRequest` を追加した。これは agent 本体の完成実装ではなく、A3 control plane が受け入れる job/result JSON shape を先に固定するための実装である。特に `AgentJobResult` は `stdout_log` / `stderr_log` / `combined_log` / `artifacts` の local path field を拒否し、A3-managed artifact store の upload reference だけを受け付ける。あわせて JSON-backed job store と `/v1/agent/jobs` / `/v1/agent/jobs/next` / `/v1/agent/jobs/{job_id}` / `/v1/agent/jobs/{job_id}/result` の pull handler を追加し、`a3 agent-server` から同 API を実 HTTP endpoint として listen できる最小 entrypoint まで追加済みである。この endpoint は local host / compose network 内の control-plane API であり、central server API ではない。さらに file-backed artifact store と `PUT /v1/agent/artifacts/{artifact_id}` を追加し、digest / byte size を A3 側で検証してから upload metadata を保存できるようにした。Go toolchain がない環境でも protocol を検証できるよう、Ruby reference agent (`a3-agent`) を追加し、1 job poll、local command 実行、combined log / artifact upload、result submit までの挙動を固定した。現在は `agent-go` module を追加し、同じ 1 job worker loop を Go standard library のみで build / test できる状態にした。`agent-go/scripts/build-release.sh` は macOS / Linux 向け archive を標準対象とし、Windows は WSL2 Ubuntu 経由で Linux archive を使う。`agent-go/scripts/install-release.sh` は archive から Go なしで binary install を行い、`CHECKSUM_FILE=dist/checksums.txt` 指定時は install 前に archive SHA-256 を検証する。`agent-go/scripts/install-local.sh` は Go がある環境で source build install を担当する。`agent-go/scripts/smoke-ruby-control-plane.sh` は Ruby control plane との protocol smoke を担当する。workspace root の compose bundle では optional `a3-agent` container と `task a3:portal:bundle:agent-smoke` を追加し、`a3-runtime` control plane から `docker-dev-env` agent container へ job を流して result / artifact upload まで通ることを確認済みである。さらに Go agent の `local_git` alias + `worktree_branch` materializer、worker protocol transport、A3 `AgentWorkerGateway` の `agent-materialized` branch、CLI の `--agent-source-alias`、`agent-go/scripts/smoke-materialized-worker-protocol.sh`、`agent-go/scripts/smoke-materialized-agent-gateway.sh` まで追加し、agent-owned workspace から worker result と descriptor-derived `changed_files` を返す end-to-end path を確認済みである。verification command も `AgentCommandRunner` と `--verification-command-runner agent-http` で agent job 化し、workspace root では `task a3:portal:bundle:agent-verification-smoke` により Portal dev-env agent image 上で remediation / verification command が成功し、A3 が task を `Merging` へ進めることを確認済みである。さらに `task a3:portal:bundle:agent-full-verification-smoke` で実 `member-portal-starters` source、`task a3:portal:bundle:agent-ui-verification-smoke` で実 `member-portal-ui-app` source に対する remediation と `task test:nullaway` を compose `a3-agent` 上で実行し、combined log upload と `Merging -> Done` の task 遷移まで確認済みである。`task a3:portal:bundle:agent-parent-topology-smoke` では synthetic `repo:both` parent と 2 child relation を作成し、parent integration ref を両 repo slot に materialize した上で agent-http verification と parent merge が `Done` まで進むことを確認済みである。`task a3:portal:bundle:agent-real-parent-full-verification-smoke` では実 Portal source 由来の isolated clone を使った `Portal#79/#80/#81` に加え、実 live repo を直接 repo source とした `Portal#88/#89/#90` で full verification と live merge を完走した。2026-04-12 の再確認では `task a3:portal:bundle:agent-smoke`、`task a3:portal:bundle:agent-worker-gateway-smoke` (`Portal#95`)、`task a3:portal:bundle:agent-verification-smoke` (`Portal#96`)、`task a3:portal:bundle:agent-parent-topology-smoke` (`Portal#97/#98/#99`) がすべて成功し、agent control-plane / worker gateway / verification runner / parent topology の各経路が `Done` まで到達した。runtime package は A3 側の `slot -> alias` contract と worker gateway option summary を公開し、Go agent は runtime profile JSON (`alias -> local path`) と `a3-agent doctor -config ...` を持つ。汎用 agent image は `docker/a3-agent`、Portal 用 dev-env agent image は `docker/a3-portal-agent` として分離し、project runtime 依存は dev-env agent 側へ閉じ込める。`a3 agent-artifact-cleanup` で diagnostic/evidence artifact の retention/GC を operator command として実装済みである。標準運用は `a3-agent --loop --poll-interval ...` を operator terminal または dev-env container で手動起動する方式に固定し、OS service template / install / load / enable は不要と判断して A3 distribution から外した。auth は `A3_AGENT_TOKEN` / `--agent-token` / profile `agent_token` による local shared bearer token を最小 contract として追加済みである。残りは agent-owned publish/merge、manual loop runbook、disk/artifact retention、長時間運用 hardening である。remote TLS / remote agent authorization scope / multi-node scheduling は現行完成条件に含めない。

補足: agent auth の現行 contract は token file と scope 分離を含む。agent 側 endpoint は `A3_AGENT_TOKEN_FILE` / `--agent-token-file` / profile `agent_token_file`、A3 control 側 enqueue/fetch endpoint は `A3_AGENT_CONTROL_TOKEN_FILE` / `--agent-control-token-file` を優先し、process arguments へ token を露出させない。control token 未設定時は local/backward-compatible path として agent token に fallback する。長時間起動する `a3-agent` と `a3 agent-server` は request ごとに token file を読み直すため、token file の atomic replace で restart なしの rotation が可能。

#### 0.4.5.2 phase model 再検討メモ

Kanboard baseline canary を通した結果、A3-v2 のような自動実行では `review` を独立 phase として持つ価値が薄く見えていた。特に軽量 task では、`review` を通しても最終的には `verification` の通過可否で戻し先が決まるため、中間 phase と Kanban 列の往復がオーバーヘッドになりやすい。2026-04-10 時点では、この再設計は fresh `single` / `child` について実装済みで、現行正本は `single/child = implementation -> verification -> merge`, `parent = review -> verification -> merge` である。

- 現行
  - `single` / `child`: `implementation -> verification -> merge`
  - `parent`: `review -> verification -> merge`
  - Kanban 上は `single` / `child = In progress -> Inspection -> Done`, `parent = In review -> Inspection -> Done`
- 第一候補
  - 将来の phase 再設計では、外部 phase を `implementation -> verification -> merge` に減らす案を最初に比較する
  - `review` は独立 phase ではなく `implementation` 内の substep として扱う
  - `implementation` 内で worker 実装、checkpoint review、findings fix、refactor、再レビューを完結させる
  - `verification` 内では remediation と runner verification を扱う
- 副案
  - `review + verification` を 1 つの phase に統合する
- 統合で維持すべき contract
  - parent task は child 完了前に verification 相当へ進めない
  - reviewer findings と runner verification failure を evidence 上で区別できる
  - lane model は現行どおり `build` と `gate` の 2 本を維持する
  - review 実行基盤の不安定さは phase 分離ではなく implementation loop 内 retry policy で吸収する
- 期待する効果
  - docs-only task のように review / verification の実質差が薄いケースで phase 遷移と Kanban 列の往復を減らせる
  - 人手運用に近い `実装 -> レビュー修正 -> リファクタ` のループを implementation に内包できる
- 検討の順番
  - まず既存の SoloBoard baseline exit rule と実 Portal source の `repo:both` parent/full verification canary を満たす
  - その後に `implementation + review` 統合案を別 task 化して設計する
  - `review + verification` 統合は副案として比較する

#### 0.4.5.3 phase redesign の次スライス

2026-04-10 時点では cleanup / retention の基盤と parent-child canary が通ったため、phase 再編は「次に着手してよい設計課題」に上がった。ただし current 正本を直接崩す段階ではなく、まず single / child を対象に移行 slice を固定する。

- slice 1 の対象
  - external phase を `implementation -> verification -> merge` に縮約する
  - 対象 task kind は `single` と `child` に限る
  - `parent` は当面 `review -> verification -> merge` のまま据え置く
- slice 1 で implementation に吸収するもの
  - worker 実装
  - checkpoint review
  - findings fix
  - refactor
  - review evidence publish
- slice 1 で保持する contract
  - `review` evidence 自体は消さず、implementation run 配下の structured evidence として残す
  - reviewer findings と verification failure は operator read model 上で別種別のまま観測できる
  - rerun policy は `review target` 差分を引き続き判定できる
  - watch-summary / operator read model / kanban lane は、runtime canonical phase が実際に減るまでは `implementation / review / inspection / merge` の internal phase をそのまま表示する
- slice 1 の acceptance
  - single canary が `implementation -> verification -> merge` で完走する
  - child canary が `implementation -> verification -> merge` で完走する
  - parent-child canary で、child 完了後に parent だけが `review -> verification -> merge` へ handoff される
  - blocked diagnosis / rerun diagnosis から `implementation failure`, `review finding`, `verification failure` を区別できる
- historical record judgment
  - persisted run に残っている `child in_review / phase=review` は current canonical flow に合わせて `verification` / `Inspection` 相当へ投影する
  - operator/read-model は過去の child review を独立 phase としては表示しない
  - historical record に review wording が summary や diagnostics に残ることは許容するが、phase/status の canonical 表示は current contract を優先する
- implementation 着手順
  - `PhasePolicy` / read model / watch summary の canonical phase を single / child だけ縮約できるよう分離する
  - `WorkerPhaseExecutionStrategy` と evidence publish を、implementation 内 review loop を表現できる payload に拡張する
  - kanban mutation rule と operator summary を新しい phase map に追随させる
  - current parent flow を壊さない regression を先に追加してから single / child を移行する

2026-04-10 追記:

- slice 1 の実装は完了し、fresh `single` / `child` は runtime / CLI / operator surface で `review` を経由しない
- historical な `child in_review / phase=review` record も operator/read-model では `verification` / `Inspection` 相当へ投影する
- `review_skill` を外部 phase surface として扱うのは parent review だけに絞った

この slice が通った後に、`parent review` を独立 phase として残すか、`review + verification` をまとめるかを再評価する。つまり phase 再編は一括置換ではなく、`single/child` と `parent` を分けた段階移行で進める。

### 0.4.6 2026-04-12 executor command template の汎用化方針

Portal runtime は `scripts/a3-projects/portal/config/portal/launcher.json` を executor 正本として読み続ける。ただし、A3 Engine が `codex exec --json`、`--model`、`model_reasoning_effort` のような Codex CLI 固有語彙を解釈する形は v1 完成条件として不十分である。

v1 では provider adapter を先に増やさず、A3 Engine が扱う executor contract を「command template + prompt/result/schema transport」に絞る。Codex を使うか、別の A-AI CLI を使うか、どの model / reasoning option を渡すかは project launcher config の command 配列へ閉じ込める。

#### 0.4.6.1 目的

- A3 domain model に model 名、provider 名、Codex CLI option を持ち込まない
- phase ごとの実行差分は `launcher.json` の command template で表現する
- worker は command template の placeholder 展開、stdin bundle 送信、result JSON 回収だけを担当する
- Codex 以外の one-shot A-AI runner も、同じ入出力契約を満たせば差し替え可能にする

#### 0.4.6.2 正本と責務

- 正本:
  - `scripts/a3-projects/portal/config/<project>/launcher.json`
- 解釈責務:
  - thin worker (`scripts/a3/a3_stdin_bundle_worker.rb`)
- 非責務:
  - `Task`, `Run`, `Evidence`, `Workspace` などの A3 domain
  - Kanban task packet
  - phase runtime config
  - A3 Engine core による model / reasoning option の解釈

model や reasoning effort は A3 の概念ではなく、project runtime が選んだ executor command の引数である。

#### 0.4.6.3 config shape

`executor.kind` は `command` とし、default command と phase override を持てるようにする。command は shell 文字列ではなく argv 配列とし、A3 は shell interpolation を行わない。
最初に固定する形は provider-neutral な command template である。Codex CLI は Portal profile の現在例にすぎず、A3 の標準実装ではない。

provider-neutral example:

```json
{
  "executor": {
    "kind": "command",
    "prompt_transport": "stdin-bundle",
    "result": {
      "mode": "file",
      "path_template": "{{result_path}}"
    },
    "schema": {
      "mode": "file",
      "path_template": "{{schema_path}}"
    },
    "default_profile": {
      "command": [
        "{{ai_command}}",
        "--input-stdin",
        "--result",
        "{{result_path}}",
        "--schema",
        "{{schema_path}}"
      ],
      "env": {}
    }
  }
}
```

Portal Codex profile example:

```json
{
  "executor": {
    "kind": "command",
    "prompt_transport": "stdin-bundle",
    "result": {
      "mode": "file",
      "path_template": "{{result_path}}"
    },
    "schema": {
      "mode": "file",
      "path_template": "{{schema_path}}"
    },
    "default_profile": {
      "command": [
        "codex",
        "exec",
        "--json",
        "--model",
        "gpt-5-codex",
        "-c",
        "model_reasoning_effort=\"medium\"",
        "--output-last-message",
        "{{result_path}}",
        "--output-schema",
        "{{schema_path}}",
        "-"
      ],
      "env": {}
    },
    "phase_profiles": {
      "implementation": {
        "command": [
          "codex",
          "exec",
          "--json",
          "--model",
          "gpt-5.3-codex-spark",
          "-c",
          "model_reasoning_effort=\"high\"",
          "--output-last-message",
          "{{result_path}}",
          "--output-schema",
          "{{schema_path}}",
          "-"
        ]
      },
      "review": {
        "command": [
          "codex",
          "exec",
          "--json",
          "--model",
          "gpt-5-codex",
          "-c",
          "model_reasoning_effort=\"medium\"",
          "--output-last-message",
          "{{result_path}}",
          "--output-schema",
          "{{schema_path}}",
          "-"
        ]
      },
      "parent_review": {
        "command": [
          "codex",
          "exec",
          "--json",
          "--model",
          "gpt-5-codex",
          "-c",
          "model_reasoning_effort=\"high\"",
          "--output-last-message",
          "{{result_path}}",
          "--output-schema",
          "{{schema_path}}",
          "-"
        ]
      }
    }
  }
}
```

#### 0.4.6.4 placeholder contract

初期実装で許可する placeholder は次に限定する。

- `{{result_path}}`
  - worker が作成する executor result JSON の出力先
- `{{schema_path}}`
  - worker が作成する structured output schema のパス
- `{{workspace_root}}`
  - 必要になった場合だけ使う host workspace root

未知 placeholder は fail-close とする。command 配列の各要素を文字列として扱い、shell 展開、環境変数展開、quote の再解釈は行わない。

#### 0.4.6.5 解決ルール

thin worker は request を見て executor profile を次の順で解決する。

1. `parent_review`
   - `phase == review && phase_runtime.task_kind == parent`
2. phase 名
   - `implementation`, `review`
3. `default_profile`
   - 上記 2 種の既知 phase に対する共通既定値としてだけ使う

未定義 phase は `default_profile` で吸収せず fail-close とする。`default_profile` は「implementation / review / parent_review に対する共通既定値」であって、未知 phase 用の escape hatch ではない。
`verification` は A-AI executor profile ではなく、project command runner / agent command runner が実行する deterministic command の phase として扱う。verification を AI executor profile へ暗黙 fallback しない。

#### 0.4.6.6 validation rule

runtime 開始時に次を validate する。

- `executor.kind == command`
- `prompt_transport == stdin-bundle`
- `result.mode == file`
- `schema.mode` は `file` または `none`
- `default_profile.command` は空でない string array
- `phase_profiles` の key は `implementation`, `review`, `parent_review` のみ
- `phase_profiles.*.command` は空でない string array
- command 内の placeholder は許可リスト内だけ
- `verification` profile は許可しない。必要な確認は verification command / remediation command として runtime package 側に定義する

未知 key、空 command、未知 placeholder は fail-close とし、暗黙 fallback で `codex exec --json` 固定挙動へ戻さない。

#### 0.4.6.7 implementation plan

1. `scripts/a3-projects/portal/config/portal/launcher.json` と `portal-dev/launcher.json` を `kind: command` へ移行する
2. `scripts/a3/a3_stdin_bundle_worker.rb` の `codex_command` / `model` / `reasoning_effort` resolver を `executor_command` / command template resolver へ置き換える
3. invalid config fallback の `["codex", "exec", "--json"]` を廃止し、設定不備は worker failure として明示する
4. current `a3-engine` / root tests に次を追加・更新する
   - default command
   - implementation command override
   - parent_review command override
   - unknown placeholder fail-close
   - invalid config fail-close
5. `Portal#131`-`Portal#143` の scheduler validation 前に、runtime smoke で command template 展開と result JSON 回収を確認する

#### 0.4.6.8 非目標

- provider adapter class の先行導入
- task ごとの model 切替
- Kanban label での model 切替
- domain / evidence への model 名の永続化
- project surface / phase runtime config への executor vendor 語彙の追加

adapter は、command template contract だけでは provider ごとの auth / streaming / result 回収差分を吸収できないと事実確認できた段階で導入を検討する。v1 completion では adapter 抽象より、実行コマンド契約を provider-neutral にすることを優先する。

#### 0.4.6.9 Codex CLI 依存の棚卸し結果

2026-04-12 時点で、完成前に扱うべき Codex CLI 依存は次の通り。

- 回収済み:
  - `scripts/a3/a3_stdin_bundle_worker.rb` の `codex_command` は `executor_command` へ置き換え、A3 worker は command template と placeholder 展開だけを扱う
  - invalid config fallback の `["codex", "exec", "--json"]` は廃止し、`["executor", "command"]` として設定不備を明示する
  - `scripts/a3-projects/portal/config/portal/launcher.json` と `scripts/a3-projects/portal/config/portal-dev/launcher.json` は `kind: command` と command argv template へ移行済み
  - `scripts/a3/diagnostics.rb` の `.codex/vendor/ripgrep/rg` と Volta 配下 Codex vendor `rg` fallback は削除済み。残す vendor fallback は `AI_CLI_HOME` / `.ai-cli` の generic path のみとする
  - `scripts/a3-projects/portal/config/portal/launcher.json` の `/Users/takuma/.codex/notify.sh` 通知 hook は削除済み
- 残存する project profile 依存:
  - Portal の current executor command profile は、実際の最終検証用 runner として `codex exec --json ...` を指定している
  - `scripts/a3-projects/portal/config/portal/launcher.json` の `runtime_env.required_bins` には、current Portal profile の実行前提として `codex` が残る
  - これは A3 Engine core の依存ではなく、Portal project が選んだ executor command profile の依存である。別 A-AI CLI へ切り替える場合は command profile と required bin を差し替える
- test fixture dependency:
  - `scripts/a3/diagnostics.rb` の generic vendor `rg` fallback は `AI_CLI_HOME` / `.ai-cli` を参照する。関連 spec も `.codex` 前提から generic path へ更新済み
  - stale な deleted legacy root script 参照 spec は削除済み。stdin bundle worker / direct canary worker の current spec は engine library を直接対象にする
  - `a3-engine/spec/a3/**/*_spec.rb` の blocked / inspection / show output fixture に `failing_command: "codex exec --json -"` が残っている。これは観測例の fixture であり runtime dependency ではないが、command template 移行時に汎用 command 表記へ更新する
- document / operation wording:
  - `docs/10-ops/10-02-codex-reporting-style.md` などの「Codex 実行者」は human/operator role 名として残っている。AI executor の hard dependency ではないため、今回の runtime 汎用化 blocker にはしない

#### 0.4.6.10 特定 AI 非依存の解決方針

A3 v1 は「特定 AI CLI adapter を内蔵する system」ではなく、「project が指定した one-shot command を、A3 が phase / workspace / kanban / evidence の文脈で呼び出す system」として固定する。

- hard dependency として禁止するもの:
  - A3 Engine core が `codex`, `--model`, `model_reasoning_effort` を意味解釈すること
  - A3 domain event / run / evidence / kanban payload に provider 固有 model 名を正規項目として持つこと
  - config 不備時に A3 が暗黙で `codex exec --json` へ fallback すること
- project profile として許容するもの:
  - Portal の現行検証 profile が `codex exec --json ...` を command argv として指定すること
  - `runtime_env.required_bins` に、その project profile が実際に必要とする executable を列挙すること
  - 別 A-AI へ切り替える際に `launcher.json` の command / env / required bins を差し替えること
- 完成前に確認すること:
  - root worker は `executor.kind=command` と placeholder 展開だけを扱い、provider 固有 resolver を持たない
  - diagnostics / reconcile / launcher tests は generic command runner と generic AI CLI vendor path を前提にする
  - final scheduler validation は現行 Portal profile として Codex CLI を使ってよいが、結果報告では「A3 core 依存」ではなく「Portal profile dependency」として扱う

- parity backlog の項目は「後で改善」ではなく、Portal live canary の blocker として扱う
- v1 で一度解決した性質は、v2 で未実装なら bug と同列に扱う
- 以後の scheduler / merge / cleanup 修正は、この監査表のどの項目を回収するものかを明示して進める

### 0.5 次の Canaries

次の live canary は、今回の `repo:starters` 単独 thin handoff canary を踏まえて、次のどちらかを小さく選ぶ。

- cross-repo child を含む parent finalize canary
  - parent merge inventory / child commit 集約 / live promotion の再確認
- `repo:ui-app` 単独 canary
  - ui-app 側の canonical flow と support repo requirement を分離して確認

優先は前者である。今回の live handoff canary で見えた gap は merge / parent inventory 寄りだったため、次は parent finalize の live canary を薄く回す価値が高い。

## 1. 目的

- A3 を共通 Docker image として配布可能にする
- bundled kanban は SoloBoard とし、compose service として A3 と同梱できるようにする
- 案件ごとの差分を A3 image rebuild ではなく runtime package と `a3-agent` 配置先 runtime で扱えるようにする
- scheduler state / workspace / evidence / artifact cache を案件単位で分離する
- 既存の project surface、workspace、evidence の責務境界を Docker 配備後も維持する

## 2. 基本方針

### 2.0 この文書でいう案件の意味

この文書でいう `案件` は、A3 の `task` や ticket とは別の概念である。

- `task`
  - A3 が実行する domain 上の実行単位
- `案件`
  - 同一 manifest / secret / scheduler state / workspace root を共有して運用する deployment boundary

つまり、1案件 runtime の中で複数 task が実行される。
workspace や run/evidence の直接の owner は task/run だが、それらを保持する storage root や runtime instance の分離単位は案件である。

### 2.1 配布単位は共通 A3 image + SoloBoard compose、利用単位は案件 runtime

A3 は次の 2 層で提供する。

- product image
  - engine 本体、標準 preset、SoloBoard adapter、CLI、runtime 依存を含む
- bundled service
  - SoloBoard container と bootstrap surface を含む
- project runtime package
  - manifest、案件固有 skill、hook、command script、案件 metadata を含む
- execution agent
  - host または project dev-env container に置き、project command 実行と log/artifact 返却を担当する

つまり、案件差分は A3 image に焼き込まず、runtime package、環境変数/secret/volume、`a3-agent` の runtime profile で与える。

### 2.1.1 write boundary は runtime package ではなく repo source injection で分ける

A3 自体は `merge_to_live` と `merge_to_parent` を domain rule として持つが、実際にどの repo source へ書き込むかは workspace root 側の injection で決める。

- scratch verification
  - `.work/...` 配下へ再作成した scratch repo source を使う
  - direct verification や parent/child completion の既定値はこれを使う
- live-write canary
  - 実 repo source をそのまま与える
  - 実行入口は scratch と task 名を分け、明示 guard を要求する

scratch repo source は「実 repo に対する `git worktree add`」ではない。live repo を親にした worktree は path だけが別でも `git-common-dir` と ref namespace を共有してしまうため、scratch / live の write boundary を分離できない。

workspace root 側の標準 helper は次の 2 層で scratch source を作る。

- scratch parent repo
  - `.work/.../portal-direct-repo-sources/.repo-store/<repo>.git` のような hidden path に置く
  - live repo から `--mirror` または同等の方法で再作成し、live と distinct な `git-common-dir` を持たせる
- scratch leaf worktree
  - `.work/.../portal-direct-repo-sources/<repo>` を実際の `--repo-source` として渡す
  - scratch parent repo に対して `git worktree add --detach` で切り出す

つまり、scratch verification の正本は `live repo -> worktree` ではなく、`live repo -> scratch parent repo -> scratch leaf worktree` である。性能とディスク効率のため worktree を使ってよいが、その親 repository は必ず live と分離された scratch 専用 repository でなければならない。

この hidden parent repo は operator surface の実装詳細であり、A3 runtime へ渡す `repo source` は leaf worktree path だけとする。cleanup / quarantine / rerun diagnosis も leaf worktree と hidden parent repo の 2 層を前提に扱う。
scratch source bootstrap は repo source 隔離のための準備手段であり、task workspace topology ではない。single / parent / child の実行 workspace は必ず dedicated branch + Git worktree を使う。APFS clone、detached checkout、`update-ref` 後同期は正規 task workspace model にしない。

bootstrap helper の owner contract もこれに従う。

- `clone/fetch` の owner
  - live repo -> scratch parent repo
- `worktree add/remove/prune` の owner
  - scratch parent repo -> scratch leaf worktree
- runtime へ注入する path
  - scratch leaf worktree のみ

つまり、`registered_worktree` / `remove_destination` / `prune` の主体は live repo ではなく scratch parent repo である。live repo は source-of-truth だが、scratch leaf worktree の owner ではない。

つまり、`merge_to_live` は常に「与えられた repo source の project-scoped live target ref へ merge する」であり、その concrete ref は runtime package (`core.merge_target_ref`) から与える。scratch か live かは product 本体ではなく injection 側の責務である。

workspace root 側の標準入口では、少なくとも次を分ける。

- scratch completion
  - workspace root が提供する direct `execute-until-idle` entrypoint
  - single-repo / multi-repo の task 名は project 注入側で分ける
  - fresh reset が必要なときだけ destructive `prepare-direct-repo-sources` を使い、継続観測の one-shot では non-destructive `ensure-direct-repo-sources` を使う
- live-write canary
  - workspace root が提供する live-write `execute-until-idle` entrypoint
  - single-repo / multi-repo の task 名は project 注入側で分ける

live-write canary は `A3_ALLOW_LIVE_WRITE=1` を要求し、誤って scratch 用 task 名と混同しないようにする。

差分あり local-live canary (`Portal#3050`) では、A3-v2 direct execution が implementation workspace の差分を `refs/heads/a3/work/...` へ commit/update し、その work ref を local live target ref (`refs/heads/feature/prototype`) へ fast-forward merge できることを確認した。remote push は行っていない。

`Portal#3051` ではこの確認を `repo:both` へ広げ、`member-portal-starters` と `member-portal-ui-app` の両方で implementation diff を `refs/heads/a3/work/Portal-3051` に publish し、それぞれの local live target ref (`refs/heads/feature/prototype`) へ反映できることを確認した。反映後の local live head は `member-portal-starters=d5f75e3811c15c504857b30edd18db79dbdf54e8`, `member-portal-ui-app=91015846e5b10378723a9f4104aa2a33d804f54b` で、どちらも `A3-v2 direct canary update for Portal#3051` を commit message に持つ。

`Portal#3052` / `Portal#3053` / `Portal#3054` ではこの確認を mixed parent/child topology の local-live diff canary へ広げ、child `Portal#3053` と `Portal#3054` の implementation diff をそれぞれ `refs/heads/a3/work/Portal-3053` / `refs/heads/a3/work/Portal-3054` に publish し、親 integration ref `refs/heads/a3/parent/Portal-3052` を経由して local live target ref (`refs/heads/feature/prototype`) へ反映できることを確認した。最終的な local live head は `member-portal-starters=1cfe365956f45c9295b69bda1e2c754ea60332bd`, `member-portal-ui-app=45192edd64c715862a8aac61e71616dda2a16404` で、remote push は行っていない。

### 2.2 1案件1 runtime instance を基本とする

初期方針では、1 つの container runtime instance は 1 案件だけを担当する。

理由:

- workspace path contract を案件ごとに独立させやすい
- scheduler state / evidence / artifact owner / log を案件境界で分離しやすい
- 誤設定時の cross-project 汚染を避けやすい
- upgrade / rollback / secret rotation を案件単位で行いやすい

同一 image を複数案件で再利用することは許容するが、同一 writable state を複数案件で共有してはならない。

### 2.3 Docker は外側の packaging であり、domain rule を上書きしない

Docker 配布後も、次は engine 側の rule として維持する。

- phase transition rule
- rerun rule
- blocked classification
- workspace existence rule
- repo slot namespace / workspace kind の意味

container 化は実行面の packaging であり、manifest や環境変数で domain semantics を差し替える場所ではない。

## 3. Product Image Contract

product image が持つものは次に限定する。

- `a3` CLI
- engine code
- 標準 preset
- SoloBoard adapter / infra 実装
- job queue / agent protocol の control plane
- Ruby runtime と必要 native dependency
- health / doctor 用の補助 entrypoint

product image が持たないもの:

- 案件 secret
- 案件固有 manifest
- 案件固有 skill / hook / verification script
- 案件 workspace
- 案件 scheduler state / evidence
- 案件固有 toolchain (`JDK`, `Maven`, `Node`, DB client, test runner など)
- project command を直接実行するための dev-env 依存

image は immutable artifact として扱い、案件運用中に container 内へ手作業で設定を書き足す前提は採らない。

### 3.1 doctor / package inspection は軽量経路で行う

`doctor-runtime` と `show-runtime-package` は、案件 runtime package の健全性確認に限定する。secret delivery は mode だけでなく、どの env key / file mount path を満たすべきかまで契約として公開する。

- full project surface / project context / container assembly を必須にしない
- runtime package descriptor だけで mount / writable root / repo source の健全性を確認する
- explicit repo source は存在だけでなく writable でもあることを確認する
- doctor が project manifest の runtime execution まで触らない
- runtime package descriptor は image ref / runtime entrypoint / doctor entrypoint を公開し、配布契約を operator が確認できるようにする
- runtime package descriptor は secret delivery mode と scheduler store migration state も公開し、doctor が fail-fast 判定に使えるようにする
- runtime package inspection は契約の列挙だけでなく、operator が次に取るべき action を summary として返せるとよい
- doctor / inspect は secret delivery と scheduler store migration の contract health を summary として返し、operator が startup checklist を判断できるようにする
- doctor / inspect は、現在の runtime package に対する `doctor` / `runtime` invocation summary も返し、operator が次に叩く入口を迷わないようにする
- doctor / inspect は、scheduler store migration が pending の場合に備えて `migration` invocation summary も返し、startup sequence を明示する
- doctor / inspect / runtime package inspection は、project runtime の薄い実地試験に使える `runtime_canary_command` を返し、doctor -> migration -> runtime の順をそのまま辿れるようにする
- `migrate-scheduler-store` は state root 配下の migration marker を更新する explicit command とし、`doctor-runtime` はその marker を読んで pending/ready を再判定する
- doctor / inspect は repo source 契約とその remediation も返し、explicit map の不足や non-writable source を operator が即座に判断できるようにする
- doctor / inspect は `startup_blockers` を返し、repo source / secret delivery / scheduler store migration / runtime path のどこで起動が止まっているかを 1 行で示す
- doctor / inspect の operator guidance は `startup blocked by ...` または `startup ready` を先頭に含み、状態要約と次アクションを同時に返す
- doctor / inspect は `persistent_state_model` と `deployment_shape` も返し、案件単位の writable state / scheduler instance / secret boundary を operator が inspection で確認できるようにする
- doctor / inspect は `networking_boundary`、`upgrade_contract`、`fail_fast_policy` も返し、outbound 境界、secret 注入原則、upgrade/migration の前提を inspection で確認できるようにする

## 4. Project Runtime Package

案件ごとの差分は runtime package として供給する。

最低限の構成例:

```text
project-runtime/
  manifest.yml
  skills/
    implementation/
    review/
  hooks/
  commands/
  config/
```

### 4.1 manifest の責務

manifest は既存設計どおり、次だけを表す。

- 利用する preset chain
- 利用する skill / command / hook
- variant 解決に必要な案件差分

manifest が持たないもの:

- phase transition rule
- rerun rule
- blocked diagnosis rule
- workspace topology rule

### 4.2 runtime package の責務

runtime package は「この案件で A3 をどう使うか」を表す。

- どの preset を採るか
- review / verification / remediation を何で実行するか
- workspace hook で何を bootstrap するか
- 案件固有の補助 script をどこに置くか

runtime package は engine code を上書きするための拡張面ではない。

### 4.3 a3-agent runtime profile の責務

`a3-agent` は runtime package の内容を解釈して A3 domain rule を実装するものではなく、A3 が発行した job を配置先 runtime で安全に実行する worker である。

runtime profile は少なくとも次を表す。

- agent name
- A3 control plane URL
- workspace root
- source aliases (`alias -> local path`)
- allowed commands
- allowed environment keys
- default working directory
- timeout / max log size
- artifact collection rules

runtime profile が持たないもの:

- phase transition rule
- task selection rule
- blocked classification rule
- SoloBoard status mutation rule

これらは `docker:a3` 側の domain/application layer が保持する。

runtime package と agent runtime profile の責務は分ける。

- runtime package: A3 が job payload に使う `repo slot -> source alias`、agent profile 名、workspace freshness / cleanup policy、worker gateway option summary を公開する。
- agent runtime profile JSON: host/dev-env 側で `source alias -> local git path` と workspace root を保持する。
- A3 doctor: profile 名、alias coverage、workspace policy 値を検査する。agent runtime filesystem には触らない。
- `a3-agent doctor -config ...`: local git path の存在、git worktree 性、dirty 状態、workspace root の書き込み可否を検査する。

A3 が発行する `workspace_request.slots` は runtime package の全 repo source slot を常に含める。
`repo:ui-app` / `repo:starters` / `repo:both` は access / sync class / ownership を決める入力であり、slot membership の filter ではない。

## 5. Container Filesystem Contract

container filesystem は少なくとも次の 3 領域へ分ける。

- read-only image layer
  - engine code、bundled preset、標準 script
- read-mostly project runtime mount
  - manifest、skill、hook、案件 script
- writable state mounts
  - scheduler store、job queue、evidence、A3-managed artifact store、operator log

初期の path 例:

```text
/opt/a3/
  lib/
  config/presets/
/project/
  manifest.yml
  skills/
  hooks/
  commands/
/state/
  scheduler/
  jobs/
  evidence/
  logs/
/artifacts/
```

path 名は実装で調整しうるが、責務分離は固定する。project workspace は `a3-agent` が配置された runtime 側にあり、A3 container の必須 writable mount ではない。A3 container が保持するのは workspace 実体ではなく、workspace descriptor、job result、artifact/evidence である。

## 6. Persistent State Model

案件 runtime が永続化する state は少なくとも次である。

- scheduler state / scheduler history
- task / run repository
- persisted evidence
- blocked diagnosis bundle
- workspace descriptor
- artifact owner cache
- operator 向け log

### 6.1 案件ごとの分離原則

次は案件ごとに独立 volume または独立 namespace を持つ。

- `/state`
- `/artifacts`

特に `artifact owner` は workspace とは別ライフサイクルだが、案件境界を越えて共有してはならない。
owner identity は task/parent 単位であっても、storage root は案件単位で隔離する。

### 6.2 Cleanup と retention

container を再作成しても、保持すべき state は volume に残る前提とする。

- terminal task workspace の cleanup は retention policy に従う
- blocked 診断に必要な evidence は scheduler cleanup と独立に残しうる
- image 更新を cleanup trigger にしない

現時点の実装状況:

- `quarantine-terminal-workspaces` により terminal workspace の退避と stale path cleanup は可能
- `cleanup-terminal-workspaces` により terminal task の `ticket workspace` / `runtime workspace` / `quarantine` を dry-run 付きで明示 cleanup できる
- `artifacts` は agent artifact store の operator cleanup として TTL + count + size cap を実装済み
- ただし `logs` / `blocked diagnosis & evidence` の retention cleanup は未実装

次段で固定する cleanup contract:

- cleanup 対象は少なくとも `ticket workspace` / `runtime workspace` / `quarantine` / `artifacts` / `logs` / `blocked diagnosis & evidence` に分ける
- `Done` / `Blocked` / `Archived` で retention を分離する
- dry-run 付きの明示 command を持ち、scheduler cycle からは opt-in で呼ぶ
- blocked 診断 bundle と evidence は workspace cleanup と独立に保持期間を持つ
- disk pressure 対策として、terminal task から古い runtime workspace を優先回収できるようにする

#### 6.2.0 Runtime 後始末と disk pressure 時の操作

SoloBoard runtime は Docker volume に runtime state を置くため、host `.work` 配下を掃除しても runtime 内の `/var/lib/a3` や SoloBoard data volume は回収されない。runtime 検証後の後始末は、host workspace cleanup と Docker cleanup を分けて扱う。

通常の検証後:

- runtime を停止する場合は root で `task a3:portal:runtime:down` を使う
- `down` は container を止めるための操作であり、SoloBoard / A3 runtime の volume を消す操作としては扱わない
- 再度検証する場合は `task a3:portal:runtime:up`, `task a3:portal:runtime:doctor`, `task a3:portal:runtime:bootstrap` の順に戻す
- runtime canary storage の古い blocked が観測を汚す場合は、削除ではなく `task a3:portal:runtime:archive-state` で退避してから観測を再開する
- 状態を一定間隔で残す場合は `ITERATIONS=3 INTERVAL_SECONDS=30 task a3:portal:runtime:observe` を使う

artifact store の掃除:

- まず `task a3:portal:runtime:agent-artifact-cleanup -- --dry-run` で削除候補を確認する
- disk pressure がある場合は TTL に加え、`--diagnostic-max-count`, `--evidence-max-count`, `--diagnostic-max-mb`, `--evidence-max-mb` を使って diagnostic/evidence 別に上限を切る
- artifact cleanup は A3-managed artifact store だけを対象にし、SoloBoard の ticket/comment/relation data は削除しない
- 2026-04-12 の `task a3:portal:runtime:agent-artifact-cleanup -- --dry-run` では `deleted_count=0`, `retained_count=0`, `missing_blob_count=0` を確認した
- 2026-04-12 の post-archive recovery smoke では `task a3:portal:runtime:doctor`, `task a3:portal:runtime:bootstrap`, `task a3:portal:runtime:smoke`, `task a3:portal:runtime:agent-artifact-cleanup -- --dry-run` が成功した。`runtime:smoke` が作成した `Portal#93/#94` は確認後に `Done` へ transition 済みである
- 同日の runtime agent smoke sweep 後にも `task a3:portal:runtime:agent-artifact-cleanup -- --dry-run` は `deleted_count=0`, `retained_count=0`, `missing_blob_count=0` を返し、artifact cleanup 対象が残っていないことを確認した
- 同日の cap 指定 dry-run (`--diagnostic-max-count 1 --evidence-max-count 1 --diagnostic-max-mb 1 --evidence-max-mb 1`) でも `deleted_count=0`, `retained_count=0`, `missing_blob_count=0` を確認した

blocked diagnosis / recovery surface の確認:

- archived state `/var/lib/a3/archive/portal-soloboard-bundle-canary-20260411T142541Z` には `Portal#43` の blocked diagnosis が保持されている
- archive を scratch copy (`/var/lib/a3/diagnostic-scratch-portal-43-20260412`) に複製し、`show-run` と `show-blocked-diagnosis` で run `572a705b-3d81-4409-b370-38cc34963b18` を表示できることを確認した
- `show-blocked-diagnosis` は `failing_command=ruby "$A3_ROOT_DIR/scripts/a3-projects/portal/portal_remediation.rb"`、`observed=exit 1`、`summary=... failed`、diagnostic stderr の `JAVA_HOME environment variable is not defined correctly` まで表示できた
- 同 scratch で `doctor-runtime` は `runtime_doctor=ok`、`repair-runs` dry-run は `actions=0`、`show-state` は `active_runs=0`, `queued_tasks=0`, `blocked_tasks=1` を返した
- 同 scratch で `cleanup-terminal-workspaces --dry-run --status blocked,done --scope ticket_workspace,runtime_workspace` は `cleaned=0`、`quarantine-terminal-workspaces` は `quarantined 0 workspace(s)` を返した。archive 正本は保持し、scratch copy は確認後に削除した

Docker 側の掃除:

- reclaimable 容量の確認は `docker system df` を使う
- build cache だけを削る場合は `docker builder prune` を使う
- image まで削る場合は `docker image prune` を使う。ただし次回 runtime 起動時に `ghcr.io/wamukat/soloboard:latest` や A3 runtime image の再 pull/build が必要になる
- `docker system prune -a --volumes` は volume を消すため、SoloBoard の検証データや A3 runtime state を破棄する意図がある場合だけ実行する

判断基準:

- 検証直後に board を目視確認したい場合は bundle を起動したままにする
- CI/long-running observation ではなく local smoke が完了しただけなら、container は止めてよい
- disk pressure が主因なら、まず artifact cleanup dry-run と Docker build cache prune を優先し、volume 削除は最後の手段にする
- 2026-04-12 の `ITERATIONS=1 INTERVAL_SECONDS=1 task a3:portal:runtime:observe` では host disk 空き約 88GiB、Docker reclaimable 約 3.7GiB、runtime state は `active_runs=0`, `queued_tasks=0`, `blocked_tasks=0` だった
- 同日の `ITERATIONS=3 INTERVAL_SECONDS=30 task a3:portal:runtime:observe` でも全 iteration で runtime doctor / watch-summary / describe-state が成功し、host disk 空き約 89GiB、Docker reclaimable 約 3.7GiB、`active_runs=0`, `queued_tasks=0`, `blocked_tasks=0` を維持した
- 同日の `task a3:portal:runtime:archive-state` では active storage を `/var/lib/a3/archive/portal-soloboard-bundle-canary-20260412T023635Z` へ退避し、直後の `task a3:portal:runtime:describe-state` / `task a3:portal:runtime:watch-summary` で新しい active storage が `active_runs=0`, `queued_tasks=0`, `blocked_tasks=0` の idle として読めることを確認した
- 同日の runtime agent smoke sweep 後の `ITERATIONS=1 INTERVAL_SECONDS=1 task a3:portal:runtime:observe` でも runtime doctor / watch-summary / describe-state が成功し、host disk 空き約 88GiB、Docker reclaimable 約 3.7GiB、`active_runs=0`, `queued_tasks=0`, `blocked_tasks=0` を確認した
- 同日の diagnostic surface 確認後に `ITERATIONS=4 INTERVAL_SECONDS=45 task a3:portal:runtime:observe` を実行し、全 iteration で runtime doctor / watch-summary / describe-state が成功した。host disk 空きは約 89GiB、Docker reclaimable は約 3.7GiB のまま維持され、各 iteration の state は `active_runs=0`, `queued_tasks=0`, `blocked_tasks=0` だった

### 6.2.1 terminal worktree cleanup 実装計画

2026-04-07 時点で、terminal task 後の workspace cleanup は「registered Git worktree を source repo から解除する責務」と「調査用 quarantine を plain copy として残す責務」がまだ完全に分離できていない。
その結果、runtime workspace 配下に次のような中途状態が残りうる。

- source repo には `git worktree` 登録が残っているが、operator からは terminal task の残骸に見える
- `repo-alpha` / `repo-beta` のような slot path が plain directory と registered worktree で不揃いになる
- `.a3` / `.m2` のような runtime residue が live repo の worktree と同じ見え方で残る

この領域の cleanup 実装は、次の contract で固定する。

- terminal task の slot workspace は、cleanup 完了時に `registered git worktree` として残してはならない
- quarantine に残してよいのは `plain copied snapshot` だけとし、`.git` は source repo の `worktrees/*` を参照してはならない
- source repo から見た registered worktree の解除と、quarantine 保存は別段階に分ける
- `ticket workspace` と `runtime workspace` は slot ごとに cleanup 可能でなければならない
- `blocked diagnosis` / `evidence` / `logs` は workspace cleanup と独立に保持期間を持つ

実装順序:

1. terminal workspace の slot を `registered git worktree` / `plain directory` / `missing path` の 3 状態で分類する
2. `registered git worktree` の場合だけ source repo 側で `git worktree remove` と `git worktree prune` を通す
3. 調査保持が必要な場合は、registered 状態のまま残さず、plain copy へ正規化して quarantine へ保存する
4. `.a3` / `.m2` / cache directory は quarantine 保持対象と cleanup 対象を分け、保持対象外は slot cleanup で回収する
5. source repo の registered worktree が解除できていない task は `cleanup completed` と見なさない

operator surface:

- `quarantine-terminal-workspaces`
  - terminal task の調査用 snapshot を plain copy として保存する
- `cleanup-terminal-workspaces`
  - source repo の worktree 登録解除
  - runtime / ticket workspace path 削除
  - quarantine の retention cleanup
  を dry-run 付きで分けて実行できるようにする

完了条件:

- terminal task 実行後に、product repo の `git worktree list` から対応 slot が消えている
- terminal task の `repo-alpha` / `repo-beta` 配下に残るものは plain directory の quarantine のみで、registered worktree 参照を持たない
- `Done` / `Blocked` の代表ケースで cleanup を再実行しても、registered worktree の取り残しや `Errno::EEXIST` を起こさない
- operator が `git status` を見たとき、terminal task の cleanup 由来で live repo が dirty に見えない

## 7. Repository Materialization Model

Docker 配布後も、repo slot / workspace rule は既存設計を維持する。

- repo slot namespace は案件ごとの task workspace で固定
- runtime package が定義する全 repo source slot は、single / parent / child と `repo:*` label に依らず workspace request に含める
- `repo:ui-app` / `repo:starters` / `repo:both` は修正対象の指定であり、agent が materialize する repo slot の選別条件ではない
- implementation は ticket workspace を使う
- review / verification / merge は runtime workspace を使う
- edit target repo は `read_write` / eager sync として扱ってよい
- non-target repo は `read_only` / lazy sync としてよいが、phase 開始前に workspace 上へ存在保証する
- phase 開始後の missing repo rescue は採らない

agent runtime 環境では、repo source の取得方法は複数ありうる。

- remote repository から agent runtime 内で materialize する
- host 側 mirror/reference repository を agent runtime に mount して materialize する
- project dev-env container の専用 local cache volume を使う
- host local workspace を agent policy の allowed workspace として使う

どの方式でも、phase 開始前の existence guarantee と source descriptor 整合を崩してはならない。
explicit map で供給された repo source は、agent doctor / inspect で writable であることも確認できるべきである。A3 doctor は source descriptor と runtime profile の整合を確認し、実 filesystem の writable / dirty / checkout 状態は agent doctor が確認する。

## 8. Runtime Configuration Model

案件 runtime は、少なくとも次の入力で起動する。

- product image version
- project manifest path
- writable state root
- A3-managed artifact root
- agent runtime profile
- agent workspace root / allowed workspace roots
- scheduler backend 設定
- repo source の取得方式
- authoritative branch / integration target の参照先
- source descriptor を解決するための repository / ref metadata
- secret / token / credential の参照先

このうち secret は environment variable または file mount で与える。
phase ごとの具体的な `SourceDescriptor` や `ReviewTarget` は task/run evidence から解決されるが、A3 runtime はそれを job として表現できる repository metadata と branch/integration 解決手段を持たなければならない。実 filesystem への materialize は agent runtime profile と agent policy に従って実施する。

禁止:

- secret を image に bake する
- manifest に secret literal を埋め込む
- workspace 配下へ credential を恒久保存する

## 9. Execution Modes

A3 container は少なくとも次の実行モードを持てるようにする。

- one-shot CLI
  - operator が個別 command を実行する
- scheduler loop
  - scheduler が継続的に runnable task を処理する
- job control plane
  - `a3-agent` が job を pull/claim し、result を返す
- doctor / inspect
  - state / config / mount / secret の健全性確認を行う

この違いは entrypoint / command の違いであり、domain model の違いではない。

project command execution は A3 container の execution mode ではない。host runtime または project dev-env container に配置した `a3-agent` の責務である。

## 10. Networking and Secret Boundaries

container が外部と通信する対象は次に限定する。

- Git hosting
- SoloBoard API
- review / LLM / worker gateway
- `a3-agent` job protocol endpoint
- package registry

案件 verification に必要な service へ直接通信するのは、原則として `a3-agent` が配置された project runtime 側の責務である。A3 container が project verification のために DB / browser / test service へ直接接続する前提は採らない。

運用原則:

- outbound 先は案件要件に応じて制限可能であること
- secret は project runtime package ではなく secret store から注入すること
- verification / review のために必要な token は案件ごとに分離すること

## 11. Upgrade and Compatibility

image upgrade は案件 runtime package と独立に行えるべきである。

### 11.1 versioning

- product image は semver または互換ポリシーつき tag を持つ
- manifest / preset schema も version を持つ
- state schema migration が必要な場合は explicit に実行する

### 11.2 fail-fast

次の不整合は起動時に fail-fast とする。

- image が要求する manifest schema と案件 manifest が合わない
- preset chain の conflict
- writable mount が不足している
- secret / token が必要条件を満たさない
- scheduler store migration が未適用

container が起動した後に曖昧な fallback で吸収しない。

## 12. Recommended Deployment Shape

初期の推奨形は次とする。

- 1案件につき 1 runtime package
- 1案件につき 1 writable state set
- 1案件につき 1 scheduler instance
- A3 image は共通 tag を再利用
- SoloBoard は compose service として同梱し、A3 側では `ghcr.io/wamukat/soloboard:latest` を既定 image とする
- project command 実行は host または project dev-env container の `a3-agent` が担当する

概念図:

```text
shared image: a3:<version>
bundled kanban: soloboard

project-a:
  runtime package A
  state volume A
  a3-agent runtime A
  workspace/source A
  artifact volume A

project-b:
  runtime package B
  state volume B
  a3-agent runtime B
  workspace/source B
  artifact volume B
```

現行設計では、複数案件を 1 control plane へ束ねない。案件ごとに local runtime、state volume、agent runtime、workspace/source、artifact volume を分ける。

## 13. Non-Goals

この文書では次を扱わない。

- Kubernetes 専用設計
- SaaS multi-tenant control plane の詳細
- Git credential broker の実装詳細
- central A3 server
- remote multi-agent pool
- multi-machine worker pool / multi-node scheduling
- remote TLS termination

ここで固定したいのは、Docker 配布時にも崩さない product/runtime/state の責務境界である。

## 14. 後続へ渡す論点

- product image に bundling する preset / sample runtime package の最小集合
- scheduler store migration の具体手順
- `a3-agent` manual loop の起動/停止/異常終了時の operator 手順
- file exchange transport を HTTP pull transport の後に追加するかの判断
- host runtime と project dev-env container runtime の profile schema / doctor surface の hardening
- local operator 向け `docker compose` テンプレートの提供範囲
- secret store 連携の標準実装

### 14.1 2026-04-11 full RSpec で観測した別領域 failures

agent runtime profile contract slice の focused verification は成功したが、`bundle exec rspec` 全体では次の既存別領域 failures を観測した。これらは agent profile / materialized gateway の変更範囲ではなく、別途棚卸しして扱う。

- merge planning fixture: `BuildMergePlan` spec が `merge_to_parent requires explicit bootstrap target_ref` で失敗している。manifest / project context fixture が現行の `core.merge_target_ref` 必須化に追従していない可能性が高い。
- scheduler loop fixture: `ExecuteUntilIdle` specs が `cleanup_terminal_task_workspaces` keyword 不足で失敗している。cleanup runner 注入追加後の spec fixture 更新漏れ。
- worker phase fixture: parent flow spec が `RunWorkerPhase` の `task_packet_builder` keyword 不足で失敗している。worker task packet builder 必須化後の spec fixture 更新漏れ。
- phase model fixture: `PlanNextRunnableTask` / `ScheduleNextRun` / `RunnableTaskAssessment` の一部が child/single review phase 廃止後の runnable rule に追従していない。
- bootstrap container builder fixture: `BaseContainerBuilder` spec が `:storage_dir` 不足で失敗している。container builder assembly context の入力 contract 変更後の fixture 更新漏れ。
- runtime environment fixture: 一部 spec が `manifest core.merge_target_ref must be provided` で失敗している。runtime config spec / CLI scheduler state spec の manifest fixture が現行 schema に追従していない。
- runtime operator summary fixture: runtime-only doctor config spec は agent runtime summary key 追加により expected hash 更新が必要だった。agent slice 内で一部修正済みだが、類似 fixture が残っていないか確認する。
- CLI watch summary fixture: watch summary の表示形式が現行 UI に変わっており、旧 `[*] #3138` 前提の expectation が失敗している。
- Portal runtime surface fixture: `a3-v2` path / manifest 名 / `python3` command 前提の spec が、現行 `a3-engine` path / runtime manifest / Ruby CLI surface に追従していない。

次に全体 green を狙う場合は、上記を production bug と spec drift に分ける。現時点の優先は fixture drift の棚卸しであり、agent materialized runtime profile の focused path は `go test ./...`、runtime package / doctor focused specs、materialized smokes で確認済みである。

2026-04-11 追跡結果:

- production bug として修正対象に含めたもの:
  - parent runnable gate は、`child_refs` に含まれる child snapshot が task store に存在しない場合も pending child として扱う。欠落 child を無視すると、parent が child 完了確認なしに `review` へ進むため、topology 不整合を安全側に倒す。
- fixture drift として修正対象に含めたもの:
  - `core.merge_target_ref` 必須化後の manifest / project context fixture。
  - cleanup / task packet / storage_dir contract 追加後の constructor fixture。
  - single / child の `review` phase 廃止後の runnable / scheduler fixture。
  - watch-summary の現行 tree UI への expectation。
  - 旧 `a3-v2` path から `a3-engine` runtime surface へ移行済みの script fixture。
- 設計正本の追従:
  - `docs/20-core-domain-model.md` の single / child phase order を現行 `implementation -> verification -> merge` に更新する。
  - `PhasePolicy` から single / child の legacy `review -> verification` transition を削除し、互換逃げ道を残さない。

## 15. この文書の完了条件

- 共通 image と案件 runtime package の責務境界が定義されている
- SoloBoard を bundled kanban として compose service に分離する方針が定義されている
- project command execution を `a3-agent` に委譲し、A3 image に project toolchain を bake しない方針が定義されている
- writable state / workspace / artifact の案件分離原則が定義されている
- Docker 化が domain rule を上書きしないことが明記されている
- upgrade / fail-fast / secret 運用の原則が定義されている
- local-first runtime が現行完成条件であり、central server / remote worker pool が非目標として明記されている
- Windows native ではなく WSL2 Ubuntu を Windows 利用時の前提にしている
- OS service 化を標準導線にせず、manual loop 起動を標準としている
- runtime package の全 repo source slot が agent workspace request に常時含まれることが定義されている
- AI executor が provider-neutral command template として定義され、Codex / model / reasoning effort が A3 domain concept になっていない
- single / parent / child の execution workspace が dedicated branch + Git worktree model に固定されている
- detached checkout / APFS clone / `update-ref` 後同期が正規 task workspace model ではないことが明記されている
- workspace / artifact / log cleanup と retention の方針が定義されている
