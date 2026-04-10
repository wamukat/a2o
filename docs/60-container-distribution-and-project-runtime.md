# A3-v2 Container Distribution and Project Runtime

対象読者: A3-v2 設計者 / PJ manifest 設計者 / 運用者
文書種別: 設計メモ

この文書は、A3-v2 を Docker コンテナとして配布し、案件ごとに利用可能にするための配布モデルと runtime packaging を定義する。
既存の domain rule や workspace rule を Docker 都合で崩さず、共通 image と案件固有 runtime を分離することを目的とする。

## 0. 進捗状況

この文書は設計メモであると同時に、container distribution / project runtime 領域の実装進捗の正本でもある。
kanban が追随していない期間でも、少なくともこの節を見れば現在地を確認できる状態を維持する。

### 0.1 現在地

- 状態
  - `a3-engine` live canary を 1 本完了し、A3-v2 direct verification では `scratch` / `local-live` / `parent-child` の 3 類型で `To do -> Done` の正規フローを確認済み
- 完了済み
  - runtime package descriptor の主要 contract を実装済み
  - `doctor-runtime` / `show-runtime-package` / `run-runtime-canary` で inspection を確認可能
  - recovery (`show-run` / `show-blocked-diagnosis` / `recover-rerun`) から runtime package guidance を参照可能
  - `migrate-scheduler-store` を含む runtime startup surface を Portal runtime で実行確認済み
  - A3-v2 専用 scheduler surface (`scheduler:run-once` / `scheduler:install` / `scheduler:reload` / `scheduler:status`) を workspace root から起動できる
  - reference project で `plan-run-once` selectable な live handoff canary を 1 本通し、implementation / review / inspection / merge / live repo 反映まで確認済み
  - A3-v2 から external kanban task を取り込み、`execute-next-runnable-task` で `To do` task を選定して `In progress` / `In review` / `Done` へ反映する direct bridge を実装済み
  - external task identity は `task_id` を正本キーとして扱い、duplicate `reference` があっても publish を誤らないよう修正済み
  - scheduler cycle 前に external kanban snapshot と reconcile する Kanban-first 運用を実装済み
  - single-repo / multi-repo の standalone task を A3-v2 direct verification で `Done` まで反映済み
  - parent/child mixed topology の direct verification を A3-v2 で `Done` まで反映済み
  - single-repo / multi-repo / parent-child の local-live diff canary を A3-v2 で完走し、local `feature/prototype` への実差分反映まで確認済み
  - Portal fresh-5 canary (`Portal#3156/#3157/#3158`) を A3-v2 で完走し、child から parent finalize まで `Done` を確認済み
  - Portal direct baseline canary (`Portal#3170/#3171/#3172`) を完走し、child merge 後に parent が review / verification / merge へ handoff されることを確認済み
  - Portal scheduler baseline canary (`Portal#3173/#3174/#3175`) を完走し、scheduler 経路でも child 2 件と parent 1 件が `Done` まで進むことを確認済み
  - scheduler-shot 正常終了時に `scheduler-shot.lock` が自動 cleanup されるよう修正し、`show-state` が `stale_shot_lock` を誤検知しないことを確認済み
  - `A3-v2#3031` / `#3119` / `#3150` / `#3151` / `#3159` は fresh-5 evidence をもって `Done` 化済み
  - legacy Portal scheduler (`task a3:portal:scheduler:*`) は fail-fast 化し、Portal 側の自動実行導線からは外した
  - recovery operator surface の `requires_operator_action` 経路を例外ではなく guidance 出力として扱うよう修正済み
- 未完了
  - worker invocation / Git backend の本格運用レベル整備
  - Redmine backend contract / bootstrap / adapter / cutover canary の実装
  - project integration で初めて見える個別調整の吸収
  - project verification 実装と repo-local gate のズレを継続棚卸しし、PMD `linkXRef` のような report-only 解決経路で parent verification が不安定化しないよう automation 向け hardening を進める
  - terminal task の workspace / artifact / log cleanup を operator command と retention policy に沿って本実装すること
  - root cleanup は current scheduler quarantine / results / logs / project-local build output (`target/`, quarantine 配下 local `.work/m2/repository`, generated reports) の age+count+size retention と disposable cache の age+size retention まで拡張済みで、scheduler idle 後の terminal workspace cleanup も自動連携済み
- `.work` inventory も current/disposable の一次分類まで完了し、`live-targets` は bootstrap source として keep、`.work/a3/issues` は top-level path のみ legacy-compatible に維持して payload は delete 対象、`.work/a3/notifications` は low-value log として retention/delete 対象に固定した

### 0.1.1 実装済みと未実装の切り分け

2026-04-06 時点では、A3-v2 は「core が未着手」ではなく、「core はかなり揃っているが Portal scheduler の実運用接続が未完」という状態である。

- 実装済み
  - runtime package / doctor / recovery / migrate-scheduler-store の core surface
  - external kanban bridge と `task_id` 基準の reconcile
  - `execute-until-idle` による direct execution
  - standalone / multi-repo / parent-child の direct verification 完走
  - local-live diff canary による live repo 反映
  - terminal workspace cleanup command
- 実装済みだが Portal scheduler では未完成
  - worker invocation contract 自体の stdin bundle 標準化
  - `a3-v2/bin/a3` から worker command を受け取る経路
  - ただし Portal scheduler から起動していた thin worker は、`stdin bundle` という名前でも内部で `codex exec --json -` を呼んでおり、v1 で合意した stdin 利用の正規経路にはまだ載っていない
- 未実装 / 未完
  - Portal scheduler から v1 合意済みの stdin worker へ正しく接続する実運用 worker path
  - Portal project で fresh task を使った scheduler-to-worker-to-live の通し再検証
  - `A3-v2#3103` に相当する operator / backend bootstrap の仕上げ
  - compatibility 資産の最終縮減と legacy 削除判断

したがって、2026-04-08 時点の次優先は新しい trigger や検証専用概念を増やすことでも、workspace root の Python utility をさらに移植することでもない。A3-v2 の product/runtime 側で得た canary evidence を前提に、compatibility 資産の縮減と legacy 削除判断を進めることである。

### 0.1.2 2026-04-08 v1 / legacy 破棄可否の現状判定

live canary と scheduler surface の検証結果に加え、workspace root の operator surface / Python utility の棚卸しと Ruby migration を進めた結果、A3-v2 は `legacy scheduler や root Python thin tooling がないと Portal canary を進められない` 段階を抜けた。現時点の未完は runtime の正当性よりも、backlog / compatibility 資産 / 削除判断の整理である。

- A3-v2 product/runtime 側で達した状態
  - direct verification と fresh canary を A3-v2 側の経路で完走できる
  - Portal 向け legacy scheduler 入口は fail-fast 化済み
  - root local utility は `run.rb` を含め Ruby へ移行済みで、`scripts/a3` 直下の Python script は retire 済み
- まだ残っている依存の種類
  - root-managed kanban adapter と compatibility launcher config
  - A3-v2 backlog 上の `A3Engine` 前提 relation / close 条件
  - legacy automation 用の運用入口と cutover / parity 文書

結論として、2026-04-08 時点の判断は次のとおりである。

- Portal canary を進めるために v1/legacy を使う必要はない
- workspace root の現役 operator surface も Python / v1 依存からは外れた
- ただし compatibility 資産と一部 docs に `A3Engine-v1` 前提が残るので、`legacy automation scripts` と `A3Engine-v1` の実削除判断はまだ保留である
- `A3-v2#2949` 系 backlog の close judgment は fresh-5 evidence で完了し、以後 `A3Engine` issue は設計参照にだけ残す
- 次は `compatibility 資産の整理` と `legacy 削除可否の最終棚卸し` を先に終えてから削除判断する

### 0.1.3 Compatibility Residual Inventory

`A3-v2#3160` では、workspace root に残っている compatibility 資産を `retire / archive / keep` に分けて扱い、2026-04-08 時点で次のように整理した。

- `retire`
  - `Taskfile.yml` 上の disabled な `a3:portal:*` / `a3:portal-dev:*` sentinel task 群
  - help / runbook / README / AGENTS 上で日常入口のように見える obsolete alias の案内
- `archive`
  - `scripts/automation/*`
  - legacy automation 向け runbook / redesign メモ
  - root surface では read-only archive helper だけを残し、実行系 / mutation 系 entrypoint は fail-fast とする
- `keep`
  - `scripts/a3/config/portal-dev/*`
  - `portal-dev` root local utility
  - `scripts/a3/bootstrap_portal_dev_repos.rb`
  - `scripts/a3/prepare_portal_launchd_config.rb`

判断理由は次のとおりである。

- `retire`
  - 誤って踏まれると legacy / v1 経路の再実行を招くため、root surface から先に除去した
- `archive`
  - `scripts/automation/*` は historical investigation には使うが、current A3-v2 operator surface では実行しない
- `keep`
  - `portal-dev` root local utility / config と `bootstrap_portal_dev_repos.rb` は synthetic stale cleanup / maintenance utility / related spec からまだ参照される
  - `scripts/a3/prepare_portal_launchd_config.rb` は `portal` doctor-env の internal helper と related spec からまだ参照される

この時点で `A3-v2#3160` の acceptance は満たしており、compatibility 資産の扱いは「retire したもの」「archive として残すもの」「current root utility を支えるため keep するもの」に分かれた。以後の削除判断は `legacy automation scripts` / `A3Engine-v1` の実削除タイミングと合わせて扱う。

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
  - `LocalMergeRunner` が `refs/heads/a3/parent/*` を `refs/heads/live` から bootstrap できるよう修正
- project-scoped live target ref を導入した後、mixed parent/child の local-live child merge では親 integration branch bootstrap がまだ `refs/heads/live` 固定で、`refs/heads/feature/prototype` を持つ project で失敗した
  - merge plan に bootstrap ref を持たせ、`LocalMergeRunner` が `merge_to_parent` でも project-scoped live target ref を使って親 integration branch を bootstrap できるよう修正
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

### 0.4.1 2026-04-08 脱v1を含む今後の実行計画

Portal fresh canary の intake と stabilisation は `A3-v2#3031` / `#3119` / `#3150` / `#3151` / `#3159` を `Done` にしたことで一段落した。以後の主題は `Portal canary を通すこと` ではなく、`A3-v2 が v1/legacy に依存せず自立すること` へ移る。

2026-04-08 時点で、A3-v2 Project で issue 管理されている主残件は `A3-v2#3103` と `A3-v2#3160` である。`A3-v2#2949` / `#2954` / `#2960` / `#2961` は fresh-5 canary と Ruby migration 後の current evidence をもって `Done` 化済みである。`#3103` は backend bootstrap の別レーン、`#3160` は compatibility 資産の retire / archive / keep 判断を担う。

次の計画は、`Portal scheduler の安定化` ではなく `A3-v2 が v1/legacy に依存せず自立すること` を先頭に置いて組み直す。2026-04-08 時点では、operator surface の入口整理と root local utility の Ruby migration は完了したため、次段は backlog / compatibility / 削除判断に移る。

1. 完了済みの前提
- operator surface の入口整理
  - root-managed kanban bridge の `a3-engine` 依存を外した
  - legacy `task a3:portal:*` / `task a3:portal-dev:*` と root local utility の役割を整理した
  - docs / runbook / launcher config の案内を、`legacy scheduler` ではなく `A3-v2` 正規入口へ寄せた
- root local utility の Python 依存棚卸し
  - `scripts/a3/*.py` を移植対象 / retain / retire に分類し、operator surface を先に固定した
  - `run.py` を含む legacy-v1 backend 中継面は `run.rb` または fail-fast に置き換えた
- Python -> Ruby migration
  - `portal_v2_watch_summary`, `portal_v2_scheduler_launcher`, `assert-live-write`, `portal_v2_verification`
  - `diagnostics`, `reconcile`, `rerun_readiness`, `rerun_quarantine`, `cleanup`
  - `bootstrap_a3_v2_direct_repo_sources`, `bootstrap_portal_dev_repos`
  - `stdin bundle worker`, `direct canary worker`, `run.rb` 相当の local utility surface
  - この結果、`scripts/a3` 直下の Python script は retire 済み

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
- baseline 完了後は、現行 `a3-engine` を `a3-engine-legacy` として退避し、そのうえで current A3-v2 を新しい `A3Engine` repo として入れ直す
- この cutover 以後は `v2` という呼称を廃止し、runtime / docs / kanban / operator surface では単に `A3` または `A3Engine` と呼ぶ
- 旧 `A3Engine-v1` は新 repo への切替後に archive または削除対象とし、進捗管理の blocker や正規参照先には使わない
- ただし、設計判断の根拠として必要な最小限の文書だけは cutover 前に別保管し、repo 履歴喪失で参照不能にならないようにする
- repo wipe を一度に行うのではなく、`a3-engine -> a3-engine-legacy` の退避、current A3-v2 からの新 `a3-engine` seed、`v2` 呼称除去、`a3-engine-legacy` の archive / 削除判断を段階的に進める

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

要するに、`legacy/v1 を削除するか` の判断と `A3Engine を新 repo として作り直すか` の判断は切り離さず、Kanboard baseline 完了後に `A3-v2 -> A3Engine` への naming cutover まで含めて一体で進める。

要するに、次の実装優先順位は `Python utility の Ruby migration` ではなく、Kanboard baseline を閉じてから `A3-v2#3103` を再開できるかを判断し、そのうえで `legacy/compatibility 資産の削減判断` を進めることである。

### 0.4.2 2026-04-06 Topology / Rerun 設計見直し

Portal fresh rerun (`Portal#3140` / `Portal#3141`) で、A3-v2 internal storage の parent/child topology が脱落し、親が子完了前に `review -> verification` へ進んだ。これは個別不具合というより、external task sync と runnable gate の設計前提がずれていることを示している。

- 実装事実
  - [kanban_cli_task_source.rb](/Users/takuma/workspace/mypage-prototype/a3-v2/lib/a3/infra/kanban_cli_task_source.rb) は、読み込んだ snapshot 集合だけから `child_refs_by_parent` を組み立てる
  - [portal_v2_scheduler_launcher.rb](/Users/takuma/workspace/mypage-prototype/scripts/a3/portal_v2_scheduler_launcher.rb) は `--kanban-status To do` を固定で渡している
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
  - v2 は [portal_v2_scheduler_launcher.rb](/Users/takuma/workspace/mypage-prototype/scripts/a3/portal_v2_scheduler_launcher.rb) が detached shot を起動し、shot 本体は `execute-until-idle` を別 process で実行している
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
| scheduler shot 分離 | legacy scheduler は detached shot を起動し、自身は待たない | [portal_v2_scheduler_launcher.rb](/Users/takuma/workspace/mypage-prototype/scripts/a3/portal_v2_scheduler_launcher.rb) が detached shot を起動し、shot 本体で `execute-until-idle` を実行する | current behavior は改善済み。compatibility launcher config は fail-fast sentinel にし、active shot は v2 launcher/process だけを正本として扱う | launchd scheduler は detached shot だけ起動し、shot 完了待ちをしない |
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
  - implementation -> review -> verification -> merge が 1 本通る
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

### 0.4.5 Kanboard standard backend plan

2026-04-10 時点で、A3 Engine の current kanban backend baseline は `Kanboard` である。`Portal` 上の Kanboard baseline canary は `Portal#3170/#3171/#3172`, `Portal#3173/#3174/#3175`, `Portal#3179`, `Portal#3180` で完了しており、current operator surface の正本は引き続きこの経路である。Redmine backend 実験は破棄し、backend 差し替えの次候補は `SoloBoard` に絞る。

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

したがって、当面の live backend は Kanboard を維持する。ただし「唯一の正規 backend」として固定し続けるのではなく、next mainline の設計課題として SoloBoard parity と migration を進め、その後に Docker/runtime packaging の標準同梱 backend を一本化する。

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
- `Project Surface` は backend 固有の domain rule を持たず、backend 差分は launcher/bootstrap/adapter に閉じる
- Redmine backend canary は破棄し、backend 差し替え対象は SoloBoard に絞る
- current operator surface や launcher contract を揺らさず、差し替えは adapter / bootstrap / Docker packaging の順に閉じ込める

#### 0.4.5.1 SoloBoard 載せ替え可否と対応計画

2026-04-10 時点の調査では、`SoloBoard` は A3 Engine の kanban backend 置き換え候補として検討可能であり、next mainline の migration target として扱う。判断根拠は、A3 Engine が Kanboard の UI や DB schema ではなく、workspace root の `task kanban:api -- ...` と `scripts/kanban/kanban_cli.py` が提供する compatibility surface に依存している点にある。実運用で踏んでいる contract は `task-snapshot-list`, `task-get`, `task-label-list`, `task-transition`, `task-label-add`, `task-label-remove`, `task-comment-create`, `task-relation-list`, `task-relation-create`, `task-create`, `label-ensure` に集中しており、backend 差分は引き続き launcher/bootstrap/adapter に閉じ込められる見込みが高い。

SoloBoard は `board`, `lane`, `ticket`, `comment`, `label`, `blocker`, `parent/child`, `transition` を持ち、A3 Engine が現在使っている operator surface の主要部分を受け止められる。さらに `GET /api/tickets/{ticketId}/comments`, `GET /api/tickets/{ticketId}/relations`, `PATCH /api/tickets/{ticketId}/transition`, `ref` / `shortRef` が OpenAPI に入っており、A3 adapter で必要だった補助 API も揃い始めている。特に `Done` 列と completion flag の分離は現行 Kanboard 運用でも `task-transition --complete` により CLI 側で吸収しているため、SoloBoard だけが新たに持ち込む制約ではない。したがって、載せ替えの主戦場は `Taskfile` と `scripts/kanban/kanban_cli.py` であり、A3 Engine runtime 本体へ backend 固有分岐を持ち込まずに進める方針を維持できる。

対応計画:

- step 1: `task kanban:api -- ...` の current contract を固定し、A3 Engine が実際に使う command/output shape を regression test で保護する
- step 2: `scripts/kanban/kanban_cli.py` に backend adapter 境界を導入し、Kanboard 実装と SoloBoard 実装を切り替え可能にする
- step 3: `project -> board`, `status -> lane`, `done flag -> isCompleted` を adapter 規約として固定し、canonical ref `Portal#123` を維持する
- step 4: relation は現行利用が濃い `subtask` と blocking 系を優先し、workspace 実使用の薄い relation kind は必要になるまで広げない
- step 5: `Taskfile` / bootstrap / doctor / up/down を SoloBoard runtime に差し替えて canary し、operator surface が維持されることを確認する
- step 5a: bootstrap には board 作成だけでなく、lane 順序整備、tag 初期化、`Portal` / `OIDC` / `A3Engine` board の初期 seed、初回 ticket 作成まで含める
- step 6: Docker/runtime packaging は SoloBoard parity 後に着手し、A3 runtime と kanban backend を同一 compose/runtime bundle として同梱する
- step 7: SoloBoard の Docker runtime を標準起動経路として整理し、`task kanban:up` / `task kanban:down` / `task kanban:logs` / `task kanban:url` がその経路を指すようにする。公開ポート番号も既存 Kanboard と同じ値を維持し、operator の接続先を変えない
- step 8: bootstrap は SoloBoard board/lane/label 初期化まで含め、既存の `Portal` / `OIDC` / `A3Engine` surface を再現できるようにする
- step 9: parity が取れるまで live backend は Kanboard のまま据え置き、SoloBoard は canary として扱う

2026-04-10 の local spike では、SoloBoard を Docker で `http://127.0.0.1:3460` に起動し、board 作成、lane 初期化、tag 作成、ticket 作成、parent/child 参照、blocker 更新、comment 作成、lane name による transition、detail / relations / comments / ticket list の取得まで確認した。したがって、bootstrap は単なる board seed ではなく「A3 current surface が要求する operator 初期化」を担うものとして設計する。

2026-04-10 の追加実装で、workspace root では次を current progress として確認した。

- `scripts/kanban/kanban_cli.py` に backend adapter 境界を入れ、`soloboard` backend で `task-get`, `task-list`, `task-snapshot-list`, `task-comment-list/create`, `task-transition`, `task-label-add/remove`, `task-relation-list/create/delete`, `task-create`, `task-update`, `label-ensure` を実行できる
- `task soloboard:doctor`, `task soloboard:api`, `task soloboard:bootstrap` を追加し、SoloBoard runtime 単体でも operator surface を踏める
- `task soloboard:smoke` を追加し、current kanban compatibility surface を SoloBoard に対して一通り打つ parity smoke を実行できる
- `task kanban:up/down/logs/url/doctor/api/bootstrap:*` は `KANBAN_BACKEND=soloboard` で SoloBoard 側へ切り替えられる
- `task kanban:smoke` も `KANBAN_BACKEND=soloboard` で generic 導線から実行できる
- `Portal`, `OIDC`, `A3Engine` の board / lane / tag bootstrap は generic `kanban:bootstrap:*` からも実行できる

したがって、step 1 から step 5a までは概ね着手済みであり、残る main work は「未使用 command contract の parity 確認」「current `.work/a3/*` state と衝突しない isolated A3 canary」「SoloBoard を live backend として切り替える judgment」「その後の Docker/runtime packaging」である。

この検討のゴールは「backend を増やすこと」ではなく、「A3 Engine runtime が backend 非依存 contract に本当に閉じているか」を current surface で実証し、Docker/runtime packaging 前に bundled kanban backend を一本化することにある。SoloBoard はその検証対象として妥当であり、実装着手時も `Project Surface` と phase rule を backend 固有都合で汚染しないことを継続条件とする。

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
  - まず既存の Kanboard baseline exit rule を満たす
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

### 0.4.6 2026-04-07 executor model selection の v1 parity 回復方針

Portal の v2 は `scripts/a3/config/portal/launcher.json` を executor 正本として読み続けているが、thin worker の `codex exec --json` 呼び出しが固定寄りで、implementation と review で model / reasoning を切り替える contract が first-class ではない。v1 で launcher config に載せやすかった executor 可変性を、v2 でも config 正本のまま回復する。

#### 0.4.6.1 目的

- Portal project ごとに executor の default を `launcher.json` で定義できる
- phase ごとに implementation / review / parent review の model を切り替えられる
- domain model に model 名や provider 名を漏らさない
- thin worker / launcher は config を読むだけにとどめ、task / run / evidence へ vendor 固有語彙を持ち込まない

#### 0.4.6.2 正本と責務

- 正本:
  - `scripts/a3/config/<project>/launcher.json`
- 解釈責務:
  - thin worker (`scripts/a3/a3_v2_stdin_bundle_worker.rb`)
- 非責務:
  - `Task`, `Run`, `Evidence`, `Workspace` などの A3 domain
  - Kanban task packet
  - phase runtime config

model 選択は「project runtime の executor 設定」であり、A3 domain rule ではない。

#### 0.4.6.3 config shape

`executor` には default profile と phase override を持てるようにする。

```json
{
  "executor": {
    "kind": "ai-cli",
    "launcher_bin": "codex",
    "argv_prefix": ["exec", "--json"],
    "prompt_transport": "stdin-bundle",
    "default_profile": {
      "model": "gpt-5-codex",
      "reasoning_effort": "medium",
      "extra_args": []
    },
    "phase_profiles": {
      "implementation": {
        "model": "gpt-5.3-codex-spark",
        "reasoning_effort": "high",
        "extra_args": []
      },
      "review": {
        "model": "gpt-5-codex",
        "reasoning_effort": "medium",
        "extra_args": []
      },
      "parent_review": {
        "model": "gpt-5-codex",
        "reasoning_effort": "high",
        "extra_args": []
      }
    }
  }
}
```

#### 0.4.6.4 解決ルール

thin worker は request を見て executor profile を次の順で解決する。

1. `parent_review`
   - `phase == review && phase_runtime.task_kind == parent`
2. phase 名
   - `implementation`, `review`
3. `default_profile`
   - 上記 2 種の既知 phase に対する共通既定値としてだけ使う

未定義 phase は `default_profile` で吸収せず fail-close とする。`default_profile` は「implementation / review / parent_review に対する共通既定値」であって、未知 phase 用の escape hatch ではない。

#### 0.4.6.5 CLI 引数への写像

`codex exec --json` へ渡す vendor 固有引数は thin worker でだけ組み立てる。

- `model`
  - `--model <value>`
- `reasoning_effort`
  - `--reasoning-effort <value>`
- `extra_args`
  - そのまま append

出力 schema / output path / stdin bundle は現行契約を維持する。

#### 0.4.6.6 validation rule

runtime 開始時に次を validate する。

- `executor.kind == ai-cli`
- `prompt_transport == stdin-bundle`
- `default_profile.model` が空でない
- `reasoning_effort` は空文字禁止
- `extra_args` は string array
- `phase_profiles` の key は `implementation`, `review`, `parent_review` のみ

未知 key や空 model は fail-close とし、暗黙 fallback で旧固定挙動へ戻さない。

#### 0.4.6.7 implementation plan

1. `launcher.json` schema を拡張する
2. `scripts/a3/a3_v2_stdin_bundle_worker.rb` に executor profile resolver を追加する
3. `a3-v2/spec/a3/a3_v2_stdin_bundle_worker_script_spec.rb` に
   - default profile
   - implementation override
   - parent_review override
   - invalid config fail-close
   を追加する
4. Portal canary で implementation の model 切替を live 確認する

#### 0.4.6.8 非目標

- task ごとの model 切替
- Kanban label での model 切替
- domain / evidence への model 名の永続化
- project surface / phase runtime config への executor vendor 語彙の追加

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

- A3-v2 を共通 Docker image として配布可能にする
- 案件ごとの差分を image rebuild ではなく runtime package 差し替えで扱えるようにする
- scheduler state / workspace / evidence / artifact cache を案件単位で分離する
- 既存の project surface、workspace、evidence の責務境界を Docker 配備後も維持する

## 2. 基本方針

### 2.0 この文書でいう案件の意味

この文書でいう `案件` は、A3-v2 の `task` や ticket とは別の概念である。

- `task`
  - A3 が実行する domain 上の実行単位
- `案件`
  - 同一 manifest / secret / scheduler state / workspace root を共有して運用する deployment boundary

つまり、1案件 runtime の中で複数 task が実行される。
workspace や run/evidence の直接の owner は task/run だが、それらを保持する storage root や runtime instance の分離単位は案件である。

### 2.1 配布単位は共通 image、利用単位は案件 runtime

A3-v2 は次の 2 層で提供する。

- product image
  - engine 本体、標準 preset、標準 adapter、CLI、runtime 依存を含む
- project runtime package
  - manifest、案件固有 skill、hook、command script、案件 metadata を含む

つまり、案件差分は image に焼き込まず、runtime package と環境変数/secret/volume で与える。

### 2.1.1 write boundary は runtime package ではなく repo source injection で分ける

A3-v2 自体は `merge_to_live` と `merge_to_parent` を domain rule として持つが、実際にどの repo source へ書き込むかは workspace root 側の injection で決める。

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

この hidden parent repo は operator surface の実装詳細であり、A3-v2 runtime へ渡す `repo source` は leaf worktree path だけとする。cleanup / quarantine / rerun diagnosis も leaf worktree と hidden parent repo の 2 層を前提に扱う。

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

live-write canary は `A3_V2_ALLOW_LIVE_WRITE=1` を要求し、誤って scratch 用 task 名と混同しないようにする。

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
- 標準 adapter / infra 実装
- Ruby runtime と必要 native dependency
- health / doctor 用の補助 entrypoint

product image が持たないもの:

- 案件 secret
- 案件固有 manifest
- 案件固有 skill / hook / verification script
- 案件 workspace
- 案件 scheduler state / evidence

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

runtime package は「この案件で A3-v2 をどう使うか」を表す。

- どの preset を採るか
- review / verification / remediation を何で実行するか
- workspace hook で何を bootstrap するか
- 案件固有の補助 script をどこに置くか

runtime package は engine code を上書きするための拡張面ではない。

## 5. Container Filesystem Contract

container filesystem は少なくとも次の 3 領域へ分ける。

- read-only image layer
  - engine code、bundled preset、標準 script
- read-mostly project runtime mount
  - manifest、skill、hook、案件 script
- writable state mounts
  - scheduler store、workspace、evidence、artifact cache、log

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
  evidence/
  logs/
/workspaces/
/artifacts/
```

path 名は実装で調整しうるが、責務分離は固定する。

## 6. Persistent State Model

案件 runtime が永続化する state は少なくとも次である。

- scheduler state / scheduler history
- task / run repository
- persisted evidence
- blocked diagnosis bundle
- workspace 実体
- artifact owner cache
- operator 向け log

### 6.1 案件ごとの分離原則

次は案件ごとに独立 volume または独立 namespace を持つ。

- `/state`
- `/workspaces`
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
- ただし `artifacts` / `logs` / `blocked diagnosis & evidence` の retention cleanup は未実装

次段で固定する cleanup contract:

- cleanup 対象は少なくとも `ticket workspace` / `runtime workspace` / `quarantine` / `artifacts` / `logs` / `blocked diagnosis & evidence` に分ける
- `Done` / `Blocked` / `Archived` で retention を分離する
- dry-run 付きの明示 command を持ち、scheduler cycle からは opt-in で呼ぶ
- blocked 診断 bundle と evidence は workspace cleanup と独立に保持期間を持つ
- disk pressure 対策として、terminal task から古い runtime workspace を優先回収できるようにする

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
- implementation は ticket workspace を使う
- review / verification / merge は runtime workspace を使う
- phase 開始後の missing repo rescue は採らない

container 環境では、repo source の取得方法は複数ありうる。

- remote repository から container 内で materialize する
- host 側 mirror/reference repository を mount して materialize する
- 専用 local cache volume を使う

どの方式でも、phase 開始前の existence guarantee と source descriptor 整合を崩してはならない。
explicit map で供給された repo source は、doctor / inspect で writable であることも確認できるべきである。

## 8. Runtime Configuration Model

案件 runtime は、少なくとも次の入力で起動する。

- product image version
- project manifest path
- writable state root
- workspace root
- artifact root
- scheduler backend 設定
- repo source の取得方式
- authoritative branch / integration target の参照先
- source descriptor を解決するための repository / ref metadata
- secret / token / credential の参照先

このうち secret は environment variable または file mount で与える。
phase ごとの具体的な `SourceDescriptor` や `ReviewTarget` は task/run evidence から解決されるが、runtime はそれを materialize 可能にする repository metadata と branch/integration 解決手段を持たなければならない。

禁止:

- secret を image に bake する
- manifest に secret literal を埋め込む
- workspace 配下へ credential を恒久保存する

## 9. Execution Modes

container は少なくとも次の実行モードを持てるようにする。

- one-shot CLI
  - operator が個別 command を実行する
- scheduler loop
  - scheduler が継続的に runnable task を処理する
- doctor / inspect
  - state / config / mount / secret の健全性確認を行う

この違いは entrypoint / command の違いであり、domain model の違いではない。

## 10. Networking and Secret Boundaries

container が外部と通信する対象は次に限定する。

- Git hosting
- issue / kanban / review API
- package registry
- LLM / worker gateway
- 案件 verification に必要な service

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
- image は共通 tag を再利用

概念図:

```text
shared image: a3:v2.x

project-a:
  runtime package A
  state volume A
  workspace volume A
  artifact volume A

project-b:
  runtime package B
  state volume B
  workspace volume B
  artifact volume B
```

将来的に複数案件を 1 control plane で束ねる場合でも、state boundary と secret boundary は案件ごとに維持する。

## 13. Non-Goals

この文書では次を扱わない。

- Kubernetes 専用設計
- SaaS multi-tenant control plane の詳細
- Git credential broker の実装詳細
- worker を別 container / 別 node へ分離する際の RPC 詳細

ここで固定したいのは、Docker 配布時にも崩さない product/runtime/state の責務境界である。

## 14. 後続へ渡す論点

- product image に bundling する preset / sample runtime package の最小集合
- scheduler store migration の具体手順
- host mirror mount と remote clone のどちらを標準とするか
- local operator 向け `docker compose` テンプレートの提供範囲
- secret store 連携の標準実装

## 15. この文書の完了条件

- 共通 image と案件 runtime package の責務境界が定義されている
- writable state / workspace / artifact の案件分離原則が定義されている
- Docker 化が domain rule を上書きしないことが明記されている
- upgrade / fail-fast / secret 運用の原則が定義されている
