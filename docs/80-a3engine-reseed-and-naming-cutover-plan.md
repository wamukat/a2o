# A3Engine Reseed And Naming Cutover Plan

## 目的

この文書は、旧 A3-v2 を current `A3Engine` として入れ直し、`v2` 呼称を廃止する cutover の実行計画と残件を整理するためのものです。
2026-04-11 時点で、current source は `a3-engine` 側へ seed 済みであり、`a3-v2/` source tree と legacy automation scripts は削除済みである。

- 対象読者: 製品開発者
- 文書種別: 設計 / 手順
- 参照元: `docs/60-container-distribution-and-project-runtime.md`

## 前提

- `Kanboard baseline` は完了しており、以後は文書上の過去証跡としてだけ扱う
- Redmine backend 実験は破棄済みで、current generic backend は SoloBoard のみである
- next の backend migration target は SoloBoard であり、Docker/runtime packaging は SoloBoard parity judgment の後に行う
- 現行 `a3-engine` は旧実装の退避後に新しい current source として利用する
- packaging freeze 入力として、current generic operator backend は SoloBoard、`task a3:portal:cutover:doctor` / `:observe` は current mainline 観測入口、`task a3:portal:runtime:*` は Docker 上 A3 runtime + SoloBoard の標準入口として扱う。旧 `task a3:portal:bundle:*` は短期 maintenance alias とする

## A-AI 非依存コンセプト

A3 は特定 AI の wrapper ではなく、kanban task、workspace、phase、evidence、merge を管理する汎用 automation engine として完成させる。Codex は A3 に内蔵された実行方式ではなく、Portal project が選択している executor command profile の一例に限定する。

- A3 Engine core は `codex`、`model`、`reasoning_effort`、`--model`、`model_reasoning_effort` を解釈しない
- AI 実行差分は `scripts/a3/config/<project>/launcher.json` の `executor.kind = command` と argv template に閉じ込める
- worker が知る contract は stdin bundle、`{{result_path}}`、`{{schema_path}}`、exit code、result JSON validation だけとする
- Codex 以外の A-AI CLI は、同じ command/result contract を満たせば A3 Engine 変更なしで差し替えられる
- provider adapter class は v1 completion の前提にしない。command template では auth / streaming / result 回収差分を吸収できない事実が出た場合だけ後続で検討する

## 進め方

1. 完了: 現行 `a3-engine` を旧実装から current source へ切り替えた
2. 完了: 旧 `a3-v2` source を新しい `a3-engine` として seed した
3. 進行中: `v2` / `a3-v2` / `A3-v2` を runtime / docs / kanban / operator surface から除去する
4. 進行中: current docs に残る旧名称は historical ref / migration note に限定する
5. 進行中: executor を Codex 固定から command template contract へ移行する
6. 次段: SoloBoard + A3 runtime + `a3-agent` の配布導線、service 化、retention hardening を閉じる

## 実施項目

### 1. Legacy 退避 (完了)

- 現行 `/a3-engine` を `/a3-engine-legacy` へ rename する
- root Taskfile, launcher, script が旧 path を直参照していないことを先に確認する
- rename 後も設計確認に必要な文書へ到達できることを確認する

### 2. New Seed (完了)

- 旧 A3-v2 の内容を新しい `/a3-engine` へ配置済み
- `bin`, `lib`, `docs`, `spec`, `config` など、A3 本体として必要な構成を整理する
- root 側から見た正規 entrypoint が新 `/a3-engine` を向くことを確認する

### 3. Naming Cutover (進行中)

- repo / directory 名
  - `a3-v2`
  - `A3-v2`
- path / storage 名
  - `.work/a3-v2/*`
  - `scripts/a3/config/*` に埋め込まれた `a3-v2`
  - launchd job / plist 名の `a3-v2`
- docs / kanban / operator 文言
  - `A3-v2` project 名
  - runbook / design docs / implementation status
  - `task a3:portal-v2:*` などの operator surface

Cutover target:

- root operator surface の正規名称は `task a3:portal:*` とする
- A3 本体 CLI の正規入口は `/a3-engine/bin/a3` とする
- current runtime storage の正規 path は `.work/a3/*` とする
- current scheduler label の正規名称は `dev.a3.portal.scheduler` とする
- `portal-v2` / `a3-v2` を含む command / path / label は compatibility 名として残さない

### 4. Legacy Judgment (進行中)

- `a3-engine-legacy` に残すもの
  - cutover 直後の rollback に必要な最小限の退避資産
- archive に回すもの
  - 履歴喪失前に別保管すべき設計文書
- 削除対象
  - 正規運用から外れ、参照先としても不要になった互換資産

2026-04-11 時点の判断:

- `a3-v2/` source tree と `.agents/skills/a3-v2-checkpoint-review` は削除済み
- `scripts/automation/*` と legacy automation skills/runbook は削除済み
- root `task automation*` は legacy disabled sentinel としてだけ残す
- current runtime / operator surface は `task a3:*`, `scripts/a3/*.rb`, `a3-engine` を正規とする
- Kanboard compatibility path は削除し、current generic backend は SoloBoard のみとする

## Rename Inventory

### Repo / Directory

- workspace directory `a3-engine`
- workspace directory `a3-v2`
- kanban project title `A3-v2`

### Runtime / Operator Surface

- `a3-v2/bin/a3`
- root Taskfile の `a3:portal-v2:*`
- `scripts/a3-projects/portal/config/portal/a3-runtime-manifest.yml`
- `scripts/a3/config/*` に残る `a3-v2` 名

### Storage / Runtime State

- `.work/a3-v2/*`
- launchd helper / plist / label に含まれる `a3-v2`
- docs 内の runtime storage 例示

### Documentation

- `a3-v2/docs/60-container-distribution-and-project-runtime.md`
- `a3-v2/docs/70-implementation-status.md`
- `a3-v2/docs/75-engine-redesign.md`
- cutover / canary / phase 説明に残る `v2` 呼称

## Concrete Inventory

### Rename 必須

- root `Taskfile.yml`
  - `a3:portal-v2:*`
  - `a3-v2/bin/a3`
  - `.work/a3-v2/*`
  - `scripts/a3-projects/portal/config/portal/a3-runtime-manifest.yml`
- root `scripts/a3/*`
  - `portal_v2_scheduler_launcher.rb`
  - `portal_v2_watch_summary.rb`
  - `portal_v2_verification.rb`
  - `prepare_portal_v2_launchd_config.rb`
  - retired direct repo source bootstrap scripts
  - retired live-write guard script
  - retired root worker wrappers (`a3_direct_canary_worker.rb`, `a3_stdin_bundle_worker.rb`)
- root `scripts/a3-projects/portal/config/portal/*`
  - `a3-v2-runtime-manifest.yml`
  - `launcher.json` の operator guidance
- root `scripts/a3-projects/portal/config/portal-dev/launcher.json`
  - `task a3:portal-v2:scheduler:*` 参照
- retired root `scripts/a3/run.rb`; current user-facing root entrypoint is `task a3:*`, and the release-bound direct entrypoint is packaged `a3`
  - legacy disabled message の `task a3:portal-v2:*`, `a3-v2/bin/a3`
- internal defaults
  - `a3-v2/lib/a3/cli.rb` の `tmp/a3-v2`
- test / spec
  - `a3-v2/spec/a3/portal_v2_*`
  - `a3-v2/spec/a3/prepare_portal_launchd_config_script_spec.rb`
  - `a3-v2/spec/a3/reconcile_script_spec.rb`

### 移行時確認

- runtime storage path
  - `.work/a3-v2/portal`
  - `.work/a3-v2/portal-ui-app`
  - `.work/a3-v2/portal-kanban-*`
  - `.work/a3-v2/portal-direct-repo-sources`
  - `.work/a3-v2/scheduler/portal/*`
- launchd surface
  - `dev.a3-v2.portal.scheduler`
  - `.work/a3-v2/scheduler/portal/dev.a3-v2.portal.scheduler.plist`
- docs 内の例示
  - `a3-v2/docs/35-repo-worktree-and-merge-flow-diagrams.md`
  - `a3-v2/docs/60-container-distribution-and-project-runtime.md`
- kanban / operator 文言
  - `A3-v2` project title
  - `task a3:portal-v2:*` 系の案内文

### Archive 候補

- `a3-v2/docs/*` のうち、cutover 後に新 `/a3-engine/docs/*` へ再配置するもの
- 旧 `a3-engine-legacy` に残る設計根拠文書
- cutover 完了後に正規導線から外す `portal-v2` 命名の履歴用記述

## Retained Docs Classification

### Keep As Current

- `a3-v2/docs/00-design-map.md`
- `a3-v2/docs/05-engineering-rulebook.md`
- `a3-v2/docs/10-bounded-context-and-language.md`
- `a3-v2/docs/20-core-domain-model.md`
- `a3-v2/docs/30-workspace-and-repo-slot-model.md`
- `a3-v2/docs/35-repo-worktree-and-merge-flow-diagrams.md`
- `a3-v2/docs/40-project-surface-and-presets.md`
- `a3-v2/docs/50-evidence-and-rerun-diagnosis.md`
- `a3-v2/docs/60-container-distribution-and-project-runtime.md`
- `a3-v2/docs/70-implementation-status.md`
- `a3-v2/docs/75-engine-redesign.md`
- `a3-v2/docs/80-a3engine-reseed-and-naming-cutover-plan.md`

理由:

- current A3 の正規設計 / 運用 / cutover 計画として使い続ける
- cutover 後は新 `/a3-engine/docs/*` の正規文書群へ寄せる

### Archive Before Legacy Drop

- `a3-engine/docs/2713-a3-cleanup-design.md`
- `a3-engine/docs/2714-ui-app-inspection-runtime-design.md`
- `a3-engine/docs/fresh-parent-authoritative-workspace-bootstrap-design.md`
- `a3-engine/docs/fresh-parent-internal-merge-bootstrap-and-relaunch-loop-design.md`
- `a3-engine/docs/issue-workspace-worktree-migration-design.md`
- `a3-engine/docs/multi-repo-invariant-stabilization-design.md`
- `a3-engine/docs/retry-budget-and-failure-signature-design.md`

理由:

- 現行判断の根拠として参照する可能性はあるが、cutover 後の operator 正規導線には置かない
- `a3-engine-legacy` 削除前に別保管しておけば十分

### Delete With Legacy Or Keep Only In Legacy

- `a3-engine/docs/portal-2981-completion-plan.md`
- `a3-engine/docs/portal-2981-completion-tracker.md`

理由:

- 旧 canary / 旧完了追跡の履歴であり、cutover 後の current A3 正規文書ではない
- 必要なら `a3-engine-legacy` にだけ残し、current `/a3-engine/docs` には持ち込まない

## Rollback

- cutover 中に不整合が出た場合は、新 `/a3-engine` を止めて `/a3-engine-legacy` へ戻す
- rollback 条件は少なくとも次を満たすまで保持する
  - root entrypoint が新 `/a3-engine` を安定参照できる
  - `v2` 呼称の rename inventory が主要 surface で反映済みである
  - Kanboard / operator surface の正規導線が新名称に揃っている

## Execution Order

### Phase 1. Freeze And Backup

- cutover 開始前に root / `a3-engine` / `a3-v2` の worktree を clean にする
- 現行 `a3-engine` の参照用 snapshot と、退避対象文書一覧を確定する
- rollback 用に `a3-engine` の現状 path と参照先を記録する

Checkpoint:

- root / `a3-engine` / `a3-v2` に未コミット差分がない
- rollback 対象の path と文書一覧が残っている

### Phase 2. Legacy Rename

- `/a3-engine` を `/a3-engine-legacy` に rename する
- root から旧 path 参照が即 fail-fast するか、または temporary shim なしでは動かないことを確認する
- `a3-engine-legacy` が rollback 元として利用可能であることを確認する

Checkpoint:

- `/a3-engine-legacy` が存在する
- rollback 時に `/a3-engine` へ戻せることが確認できる

### Phase 3. New Seed

- 旧 A3-v2 の内容を新 `/a3-engine` として配置済み
- `bin`, `lib`, `docs`, `spec`, `config` の必要構成を揃える
- root 側の実行入口から、新 `/a3-engine` を参照できるようにする

Checkpoint:

- 新 `/a3-engine` が存在する
- root から A3 本体の主要入口を解決できる

### Phase 4. Operator Surface Rename

- `a3:portal-v2:*` を新名称へ切り替える
- `a3-v2/bin/a3`、`portal_v2_*` script、manifest / launcher 名を新名称へ寄せる
- launchd / plist / job label の `a3-v2` を新名称へ切り替える

Checkpoint:

- operator surface で `portal-v2` / `a3-v2` を案内しない
- 旧 surface が残る場合は compatibility ではなく明示的な移行メモに限定される

### Phase 5. Storage And Documentation Rename

- `.work/a3-v2/*` の扱いを決め、rename するか migration 手順を定義する
- docs / runbook / kanban project title の `A3-v2` を新名称へ寄せる
- history 用に残す記述と、正規導線として残してはいけない記述を分離する

Checkpoint:

- docs / kanban / storage 例示の正規名称が揃う
- archive 候補と削除対象が区別される

## Rollback Checkpoints

### Checkpoint A: Legacy Rename 直後

- 戻し方:
  - 新規 seed を行う前に `/a3-engine-legacy` を `/a3-engine` へ戻す
- 戻す条件:
  - root から新 path を前提にした変更へ着手していない

### Checkpoint B: New Seed 直後

- 戻し方:
  - 新 `/a3-engine` を退避または削除し、`/a3-engine-legacy` を `/a3-engine` へ戻す
- 戻す条件:
  - 新 `/a3-engine` の入口解決が unstable
  - 基本文書や config の配置が不足している

### Checkpoint C: Operator Surface Rename 中

- 戻し方:
  - root Taskfile / launcher / script の rename を巻き戻し、`/a3-engine-legacy` ベースへ戻す
- 戻す条件:
  - operator command が fail-fast ではなく壊れた中間状態になる
  - launchd / plist / storage path が混在して運用導線が読めなくなる

### Checkpoint D: Final Cutover 前

- 戻し方:
  - docs / kanban project rename の前で止め、`/a3-engine-legacy` ベースの名称に戻す
- 戻す条件:
  - rename inventory の未反映が広く、正規名称を確定できない

## Cutover-Day Runbook

### Step 0. Preflight

- root / `a3-engine` / `a3-v2` の worktree が clean であることを確認する
- `a3-engine-legacy` へ退避する対象 path と rollback 条件を再確認する
- rename inventory と retained docs classification を手元に置く

Go:

- worktree がすべて clean
- rollback 元の path と退避文書一覧が確定している

Stop:

- 未コミット差分がある
- rollback 条件が曖昧なまま

## Preflight Checklist

### Repository State

- root worktree が clean
- `a3-engine` worktree が clean
- `a3-v2` worktree が clean
- cutover 対象 path に未追跡の一時ファイルが残っていない

### Backup / Rollback

- `a3-engine -> a3-engine-legacy` の rollback 手順を確認済み
- 退避対象文書一覧が確定している
- `a3-engine-legacy` に残すものと archive へ出すものの区分が確定している

### Inventory

- rename inventory の current 版を参照できる
- retained docs classification の current 版を参照できる
- operator surface rename 対象が列挙済みである

### Operator Surface

- `task a3:portal-v2:*` など旧名称の current surface を把握している
- `.work/a3-v2/*` と launchd label の rename 方針を確認済み
- cutover 中に使う確認コマンドを決めている

### Go / Stop

Go:

- 上記 checklist がすべて満たされている

Stop:

- 1 項目でも未確定がある
- rollback の入口が説明できない

## Kanban Rename Plan

### Current Assumption

- current 実装 planning は `A3Engine` project で進める
- legacy planning / 廃案メモとして `A3-v2` project が残る可能性がある
- cutover 後に新規 task を `A3-v2` project へ追加しない

### Execution Order

1. cutover 前に `A3-v2` project の open task を棚卸しし、継続対象と廃案対象を分ける
2. 継続対象があれば `A3Engine` project へ移すか、新しい `A3Engine#...` task として切り直す
3. `A3-v2` project に残す task は、履歴または廃案であることが分かる title / description に揃える
4. operator runbook / docs / comment template から `A3-v2#...` の current ref を外し、`A3Engine#...` を正規にする
5. cutover 後の運用では `A3Engine` project 以外を current task source として扱わない

### Canonical Ref Handling

- current task の canonical ref は `A3Engine#...` に統一する
- `A3-v2#...` は履歴参照としてだけ残し、current task 参照には使わない
- docs 内で旧 ref を残す場合は、archive / historical context と明示する

### Legacy Ref Mapping

- `A3-v2#...` から `A3Engine#...` へ切り替えた task は、対応表を cutover 文書か kanban comment に残す
- 新しい `A3Engine#...` task を切り直した場合は、description 先頭に旧 ref を `legacy ref: A3-v2#...` と明記する
- `A3-v2` project 側に残す task には、移行先がある場合 `migrated to A3Engine#...` を追記する
- この対応表は cutover 完了後もしばらく保持し、旧 docs / comment / commit から追跡できる状態を残す

### Verification

- `task kanban:api -- task-find --project 'A3Engine' --query 'A3-v2'` で current task 本文に旧 ref が残っていないことを確認する
- `task kanban:api -- task-find --project 'A3-v2' --query ''` で残存 task が履歴 / 廃案だけであることを確認する
- current task を切り直した場合は、`legacy ref:` または `migrated to` の記述で対応付けを追跡できることを確認する
- cutover 後の新規 task 起票と status 更新が `A3Engine` project だけで完結することを確認する

## Acceptance Verification Set

### Repository / Path

- root から `a3-engine` path を解決できること
- `a3-engine-legacy` が rollback 元として残っていること
- `a3-v2` 直参照を current operator surface が要求しないこと

### Operator Surface

- current task / runbook が `task a3:portal:*` を案内していること
- launcher / manifest / helper script の current 導線が `/a3-engine/bin/a3` と新 `/a3-engine` を向いていること
- cutover 後の標準コマンドとして `task a3:portal:*` が runbook 通りに実行できること

### Kanban / References

- current planning task の canonical ref が `A3Engine#...` に揃っていること
- `A3-v2#...` が current task source ではなく履歴参照としてだけ残ること
- current docs / comment template に `A3-v2` を正規名称として残していないこと

### Pass / Fail

Pass:

- 上記確認がすべて通る
- rollback へ戻す理由が残っていない

Fail:

- current 導線のどこかが旧 path / 旧名称へ依存している
- `task a3:portal:*` と `/a3-engine/bin/a3` のどちらかが current 正規入口として成立しない
- canonical ref と project 運用が cutover 後も二重化している

### Rollback Trigger

- current operator surface の検証で `a3-engine-legacy` へ戻さないと継続できない不整合がある
- `A3-v2` project を current task source から外せない
- current docs / runbook の修正だけでは解消できない rename 漏れが残る

## Legacy Archive Exit Criteria

### Keep As Rollback Window

- cutover 後の acceptance verification が完了するまで `a3-engine-legacy` を保持する
- operator surface rename が current 導線で安定するまで削除しない
- current task source と docs 正規名称が `A3Engine` に揃うまで rollback 元として残す

### Move To Archive

- rollback が不要になり、参照価値のある設計文書だけが残る状態になったら archive へ移す
- archive 対象は current `/a3-engine` へ持ち込まない historical docs とする
- archive 先の正本は `/a3-engine/docs/archive/a3-engine-legacy/` とする
- archive 化した後も、必要な参照先は cutover 文書から辿れるようにする
- `archive-index.md` などの一覧を同 archive 配下に置き、legacy から移した文書を追跡できる状態を「退避完了」とする

### Delete

- rollback window が閉じ、archive 対象が `/a3-engine/docs/archive/a3-engine-legacy/` へ退避済みになったら `a3-engine-legacy` を削除できる
- current operator surface と current docs が legacy path を参照していないことを削除条件にする
- 削除前に、legacy にしかない current 価値のあるファイルが残っていないことを確認する

### Stop / Go

Go:

- acceptance verification 完了
- archive 対象が `/a3-engine/docs/archive/a3-engine-legacy/` へ退避済みで、index から辿れる
- current 導線から `a3-engine-legacy` 参照が消えている

Stop:

- rollback を捨てるには早い不確定事項がある
- current docs / scripts / task body に legacy path が残る
- archive 先へ移していない文書が残る

## Storage And Runtime-State Migration Policy

### Default Policy

- `.work/a3-v2/*` は rename migration せず、cutover 後は `.work/a3/*` に fresh state を作る
- launchd / plist / label も旧名を引き継がず、`dev.a3.portal.scheduler` を基準に再生成する
- cutover 当日は runtime state の持ち越しよりも current operator surface の一貫性を優先する

### When Migration Is Not Needed

- cutover 時点で active scheduler / active run / queued task が残っていない
- diagnostics や evidences を historical record としてだけ保持すれば足りる
- current operator が `.work/a3-v2/*` を参照しなくても困らない

### If Historical State Must Be Retained

- `.work/a3-v2/*` は current runtime storage に混ぜず、archive 扱いで別保管する
- 旧 launchd plist / label は archive 証跡として残しても、current launch target にはしない
- historical state を current runtime の bootstrap 入力として使わない

### Verification

- cutover 後の runbook が `.work/a3-v2/*` を current path として案内していないこと
- current scheduler / launcher が `dev.a3.portal.scheduler` と `.work/a3/*` を基準にしていること
- fresh state で `.work/a3/*` 上の one-shot / scheduler bootstrap が成立すること

## Legacy Surface Fail-Fast Policy

### Policy

- `portal-v2` / `a3-v2` を含む旧 operator surface は current 導線として残さない
- compatibility alias や自動転送は置かず、誤実行時は fail-fast で止める
- 旧 surface の案内は migration note だけに限定し、standard runbook には載せない

### Operator Guidance

- 旧 task 名や script 名を実行した場合は、新しい `task a3:portal:*` と `/a3-engine/bin/a3` を案内する
- migration note には「旧名称は互換なしで廃止済み」と明記する
- cutover 後の docs / task body / comment template は current surface だけを案内する

### Verification

- current docs に `task a3:portal-v2:*` や `a3-v2/bin/a3` を current command として残していないこと
- 旧 surface を残す記述があっても、それが historical context または migration note に限定されていること
- operator が current surface だけで日常運用できること

## Cutover Sign-Off Evidence Set

### Required Evidence

- cutover 実施コミット一覧
- acceptance verification の実行コマンドと pass 結果
- kanban status 確認結果
- rollback を発動しなかった理由

### Sign-Off Record

- cutover 完了 comment か runbook 実施記録に、上記 evidence を 1 箇所へ集約する
- sign-off には current operator surface、current runtime storage、current canonical ref が正規名称へ揃ったことを明記する
- archive / delete 未完了項目が residual として許容される場合は、その残件と follow-up ref を明記する
- sign-off を止めるのは、residual として切り出せない current 導線の不整合が残る場合に限る

### Verification

- sign-off を読めば、何を確認して cutover を受け入れたかが分かること
- rollback を見送った理由が後から追跡できること
- cutover 完了報告と plan 文書が矛盾しないこと

## Cutover Command Inventory

### Preflight

- `git status --short`
- `git -C a3-engine status --short`
- `git -C a3-v2 status --short`
- `git diff --check`
- `git -C a3-engine diff --check`

### Rename / Seed

- `mv a3-engine a3-engine-legacy`
- `mkdir a3-engine`
- `rsync -a --exclude '.git' --exclude '.work' --exclude 'tmp' --exclude 'log' a3-v2/ a3-engine/`
- `git -C a3-engine init -b main`
- `test -x a3-engine/bin/a3`

### Verification

- `task kanban:api -- task-find --project 'A3Engine' --query ''`
- `task kanban:api -- task-find --project 'A3-v2' --query ''`
- current operator surface の代表コマンドとして `task a3:portal:*`
- A3 CLI の代表コマンドとして `/a3-engine/bin/a3`

### Stop / Go Reference

- preflight / verification で失敗したコマンドは、その場で stop 条件として扱う
- `git diff --check` 系、kanban confirmation、current surface 実行確認を最低限の go 判定に使う
- runbook ではこの command inventory を参照し、個別の手順はここから逸脱しない

## Cutover Execution Ownership

### Root Operator

- root 側の Taskfile / launcher / kanban confirmation を担当する
- cutover 当日の status 更新と sign-off comment も担当する

### A3Engine Operator

- `a3-engine-legacy` 退避、新 `/a3-engine` seed、docs 更新を担当する
- `/a3-engine/bin/a3` と current runtime surface の確認を担当する

### Stop / Go Owner

- stop / go 判断は司令塔 1 名に集約する
- 各担当は fact を返し、継続可否の最終判断は stop/go owner が持つ

### Reviewer / Sign-Off

- reviewer は cutover 後 evidence と acceptance verification を監査する
- sign-off は reviewer findings なしと stop/go owner の完了承認で成立する

## Post-Cutover Residual Tracking Policy

### Allowed Residuals

- archive 整理の残件
- historical docs の wording cleanup
- current 導線に影響しない軽微な rename 漏れ
- historical `A3-v2#...` ticket ref

### Not Allowed As Residual

- current operator surface に残る旧名称依存
- current runtime storage / launch target の未整理
- cutover acceptance を再判定させるレベルの不整合
- `a3-v2/` source tree や legacy automation scripts を current 実行経路として復活させること

### Tracking

- cutover 完了後の残件は、新しい follow-up task を `A3Engine` project に切って追跡する
- cutover 完了 comment には residual の有無と follow-up ref を記載する
- residual が 0 件なら、その旨を sign-off に明記する

### Completion Boundary

- cutover 本体の完了は acceptance と sign-off で判定する
- residual follow-up は cutover 完了後の別レーンとして扱う
- residual があっても、current 導線を壊さない範囲に限って cutover 完了を許容する

## Workspace Hygiene Follow-Up Inventory

### Purpose

- cutover 後の current operator surface が安定していても、`.work` 配下の historical state / cache / logs が残り続けると disk full を再発させる
- この問題は単発 cleanup ではなく、`何を current として保持し、何を archive/delete できるか` を棚卸しして retention policy に落とす必要がある

### Inventory Targets

- `.work/a3/*`
  - current scheduler / state / workspaces / results / logs / repos / live-targets のうち、runtime 継続に必須なものと再生成可能なものを分ける
- `.work/a3-v2/*`
  - historical runtime state / old scheduler store / direct repo sources / quarantine は current runtime では使わない。disk pressure 時は delete 対象とし、必要な historical evidence は git history / docs に委ねる
- `.work/cache/*`
  - `m2-seed` などの bootstrap cache を、再生成前提で delete 可能にするか、size cap を持つ shared cache として残すかを決める
- `.work/automation/*`
  - legacy automation logs / issue workspace / codex-home は current A3 導線から切り離し済み。残存していれば delete 対象とする
- project-local build outputs under current workspaces
  - `target/`, local `.work/m2/repository`, generated reports を task terminal cleanup の対象に含めるか、rerun/recovery 用 evidence として一定期間保持するかを決める
- non-current side systems
  - `.work/plane-selfhost`, `.work/planka`, `.work/redmine` のような current Portal canary と無関係な runtime を、保守対象か disposable cache かで分類する

### Planning Questions

- current Portal canary / scheduler を壊さずに削除できる path はどこまでか
- blocked diagnosis / rerun investigation に必要な最小証跡は何か
- `results`, `logs`, `quarantine`, `workspaces`, `m2 cache` に age / size / count のどの retention rule を掛けるべきか
- terminal task 完了時に即削除するものと、operator 明示 command でだけ削除するものをどう分けるか
- `.work/a3-v2/*` や legacy automation 資産の残骸が残っていないか、disk pressure 時に再棚卸しする必要があるか
- disk pressure を検知したときの fail-fast / warning / auto-cleanup のどこまでを A3 本体責務にするか

### Expected Outputs

- current runtime に必須な path と disposable path の一覧
- `.work` cleanup command inventory
- retention policy の設計メモ
- follow-up task refs
  - artifact store / logs / blocked diagnosis evidence retention の長時間運用検証
  - historical `.work/a3-v2/*` / `.work/automation/*` 残骸の delete 確認
  - cache/log size cap
- current 進捗メモ
  - root cleanup は current scheduler quarantine (`.work/a3/portal-kanban-scheduler-auto/quarantine/*`) と legacy results/logs に age+count+size retention を掛けられる状態まで進めた
  - disposable cache (`.work/cache/m2-seed`) と quarantined build outputs (`target/`, `.work/m2/repository`, generated reports) も age+size で候補化できる
  - scheduler-loop は idle 到達後に quarantine と terminal workspace cleanup を自動実行する
  - 次段の未完は artifact/log/evidence retention と `.work` 全体の長時間運用検証

### Current `.work` Inventory Snapshot

- keep as current runtime
  - `.work/a3/portal-kanban-scheduler-auto`
    - current Portal scheduler の state root
    - `tasks.json`, `runs.json`, `scheduler_journal.json`, active `workspaces/` を含む
  - `.work/a3/state`
    - current root utility / pause control / active-run state
  - `.work/a3/scheduler`
    - current launchd plist / stdout / stderr
  - `.work/a3/env`
    - current launchd env file
- keep as reusable bootstrap source
  - `.work/a3/repos/portal-dev/*`
    - portal-dev repo mirror。current Portal scheduler の state rootではないが、bootstrap source として維持
- retention managed / disposable
  - `.work/a3/portal-kanban-scheduler-auto/quarantine/*`
  - `.work/a3/results/*`
  - `.work/cache/*`
  - `.work/kanban/trace.log`
- keep as reusable live target source
  - `.work/a3/live-targets/portal-dev/*`
    - `portal-dev` bootstrap が参照する live target mirror。current Portal scheduler の state root ではないが、delete 候補にはしない
- effectively empty or low-value in current root
  - `.work/a3/issues`
    - current root では実質空で、legacy-compatible path の残骸に近い
  - `.work/a3/notifications`
    - `automation-events.jsonl` のみ。current operator flow の必須 state ではない

### Current Judgment

- `portal-kanban-scheduler-auto` は current runtime のため delete 対象にしない
- `portal-kanban-scheduler-auto/quarantine/*` は retention policy の対象で、evidence 保持期間を超えたら delete 候補
- `results/logs/cache` は disposable として扱い、operator cleanup または scheduler idle cleanup の管理下に置く
- `.work/a3/live-targets/portal-dev/*` は `portal-dev` bootstrap の参照先のため delete 候補にしない
- `.work/a3/issues` は current runtime では使わない。rerun readiness / quarantine utility が legacy-compatible path として参照するため、top-level path だけ残して中身は空運用でよい
- `.work/a3/issues/*` に payload が残っている場合は delete 候補とし、retention 対象にしない
- `.work/a3/notifications/automation-events.jsonl` は low-value log として retention/delete 対象にする

## Documentation Update Order

### Order

1. current runbook と cutover plan を新名称へ揃える
2. docs map / implementation status の正規導線を更新する
3. root operator docs を current surface に揃える
4. archive 対象 docs を current docs から分離する
5. historical context と migration note のみ旧名称を残す

### Verification

- docs map が current `/a3-engine/docs/*` を正規導線として案内していること
- implementation status が current 名称に揃っていること
- root operator docs が `task a3:portal:*` など current surface を正規入口として案内していること
- archive docs と current docs が混在していないこと

### Documentation Sign-Off

- current docs から cutover 後の operator surface を辿れること
- archive に残した旧名称記述が historical context に限定されていること
- documentation sign-off は cutover sign-off evidence の一部として扱う

### Step 1. Legacy Rename

- 完了済み。旧実装の退避と current `a3-engine` seed は実施済み
- root から旧 path を前提にした current 実行が残っていないかは継続 spot check 対象

Go:

- current `a3-engine` が存在する
- root operator surface が current `a3-engine` を参照する

Stop:

- current operator surface から `a3-v2/` を要求する参照が見つかる

Rollback:

- rollback は想定しない。旧資産は git history / cutover evidence から辿る

### Step 2. New Seed

- 完了済み。旧 A3-v2 由来の current source は `/a3-engine` 側へ配置済み
- `docs`, `bin`, `lib`, `spec`, `config` の必要構成を current source として維持する
- root から新 `/a3-engine` の主要 entrypoint を解決できるか確認する

Go:

- current `/a3-engine` が存在する
- 主要 entrypoint の path 解決が通る

Stop:

- seed 後に基本構成が欠ける
- root から path 解決が不安定

Rollback:

- rollback は想定しない。破損時は current `/a3-engine` を通常の git revert / fix-forward で修正する

### Step 3. Surface Rename

- root Taskfile の `a3:portal-v2:*`
- `a3-v2/bin/a3`
- `portal_v2_*` scripts
- manifest / launcher / launchd label / `.work/a3-v2/*`
を rename inventory に沿って切り替える

Go:

- operator surface が新名称を案内する
- 旧名称は移行メモか履歴文書にだけ残る

Stop:

- command 名、storage 名、docs 名が混在して正規導線が読めない

Rollback:

- Step 2 の新 `/a3-engine` は維持したまま、surface rename だけを巻き戻す
- 必要なら Step 2 まで戻して `a3-engine-legacy` ベースへ戻す

### Step 4. Final Verification

- rename 後の docs / Taskfile / launcher / storage path を spot check する
- kanban project title や operator guidance の正規名称を確認する
- archive 候補と delete 候補が分離されていることを確認する

Go:

- cutover 計画文書と実 surface が一致する
- rollback 不要と判断できる

Stop:

- 正規名称が揃わない
- archive / delete 判断が未確定

Rollback:

- Step 3 以前の checkpoint に戻る
- cutover を完了扱いにしない

## 完了条件

- current `/a3-engine` が正規 source として使われている
- `v2` 呼称廃止の rename inventory が揃い、current 実行経路から旧名称が除去されている
- `a3-v2/` source tree と legacy automation scripts が current 資産として残っていない
- current docs に残る `A3-v2` は historical ticket ref / migration note に限定されている
- 次段の配布計画が SoloBoard + A3 runtime + `a3-agent` 前提へ整理されている
