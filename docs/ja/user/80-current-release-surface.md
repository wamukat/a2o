# 現在の公開機能

A2O 0.5.60 で現在利用できる公開機能と検証範囲を示す。

この文書は、リリース時点で「利用者に案内してよい機能」と「検証済みとして扱える範囲」を確認するための一覧である。導入手順を知りたい場合は [10-quickstart.md](10-quickstart.md)、設定項目を知りたい場合は [90-project-package-schema.md](90-project-package-schema.md) を読む。

## 利用可能なコマンドと機能

- ホスト用ランチャーの導入: `a2o host install`
- バージョン確認: `a2o version`
- ホスト環境の診断: `a2o doctor`
- プロジェクトパッケージの作成・検証・初期化: `a2o project template`、`lint`、`validate`、`bootstrap`
- ワーカー補助コマンド: `a2o worker scaffold`、`a2o worker validate-result`
- カンバンサービスの起動・外部 Kanbalone 診断: `a2o kanban up`、`doctor`、`url`
- エージェント対象の判定とバイナリの書き出し: `a2o agent target`、`a2o agent install`
- ランタイムコンテナの起動・停止: `a2o runtime up`、`down`
- 手動でのランタイム実行: `a2o runtime run-once`、`a2o runtime loop`
- 常駐スケジューラの再開・停止予約・状態確認: `a2o runtime resume`、`pause`、`status`
- ランタイム診断・復旧: `a2o runtime image-digest`、`doctor`、`watch-summary`、`logs [task-ref] --follow [--no-children]`、`describe-task <task-ref>`、`skill-feedback list`、`skill-feedback propose`、`reset-task <task-ref>`、`force-stop-task <task-ref> --dangerous`、`force-stop-run <run-ref> --dangerous`、`show-artifact <artifact-id>`
- 親タスクの log follow は、実行中の子タスクが完了して別の子または親タスク側へ処理が移っても、親グループを追跡し続ける。
- `watch-summary` は review の rework / reject を `x` として表示し、後続の正常な review 完了後は成功 marker に戻す。
- correction retry を使い切った invalid worker result は salvage 診断として保持されるため、operator は拒否された payload を失わずに確認できる。
- review rework 後の implementation retry には、直前の review feedback が worker runtime context として渡される。
- operator が付与した `blocked` label は phase 完了時にも保持され、runtime status publication によって暗黙に外されない。
- parent review の clean success result は、worker が `review_disposition` を省略または一部だけ返しても completed disposition に正規化される。明示的に矛盾する disposition は引き続き拒否される。frozen worker payload でも、この正規化で scheduler がクラッシュしない。
- multi-project runtime context は runtime storage、host log / workspace、scheduler pid / log file、temp file、branch namespace を解決済み project key ごとに分離する。`a2o runtime resume --all-projects`、`pause --all-projects`、`status --all-projects` は登録 project ごとに scheduler を1つずつ扱い、各 project 内の active task は1件のまま維持する。
- アップグレード診断: `a2o upgrade check`
- 単一ファイルのプロジェクトパッケージ設定: `project.yaml`
- investigate decomposition MVP: `runtime.decomposition.investigate.command`、`runtime.decomposition.author.command`、`a2o runtime decomposition investigate`、`propose`、`review`、`create-children`、`accept-drafts`、`status`、`cleanup`
- `trigger:investigate` 付き source ticket は decomposition request であり、`repo:*` scope label は不要である。`trigger:auto-implement` で実行する implementation child には、引き続き適切な repo label が必要である。
- `a2o runtime decomposition investigate`、`propose`、`review` は、project 側が所有する decomposition command を host agent 経由で実行する。runtime container は orchestrator のまま維持しつつ、implementation worker と同じ host workspace 境界で実行するため、Copilot など host 側にしかない agent CLI を decomposition command から呼び出せる。
- decomposition command UX: `a2o runtime decomposition <action> --help` の action-level help と、単発 decomposition command の外部 task 同期 / 照合
- requirement decomposition の source ticket は要求 artifact として扱う。decomposition 成功後は `Done` に移動し、A2O は別の generated implementation work を作成する。traceability のため source ticket から generated implementation parent へ Kanbalone の `related` relation を作る。
- decomposition source ticket が外部 issue から import されたものの場合、A2O は正規化した remote metadata を child-creation evidence の `source_remote` に残し、Kanbalone v0.9.28 以降では generated parent に non-tracking な `externalReferences[source]` も書き込む。古い外部 Kanbalone endpoint では relation / evidence による traceability を維持し、generated ticket 本文へ remote metadata をコピーする代わりに child-creation warning を記録する。
- decomposition の進捗は `a2o runtime watch-summary` で見える。active な source ticket がある場合は scheduler summary が running になり、task tree は source を running として表示し、`Decomposition` section は active stage を表示する。
- `a2o runtime logs <source-ref> --follow` は decomposition source ticket に対して、decomposition status を polling し、取得可能な investigate / propose / review action log を stream 表示する。decomposition follow 非対応とは表示しない。
- decomposition proposal の `depends_on` は、生成された child ticket 間の Kanban `blocked` relation に変換される。依存先は proposal の `boundary` と生成済み `child_key` の両方で解決される。
- `a2o runtime decomposition accept-drafts` は選択した draft child に `trigger:auto-implement` を付けて承認する。任意で `a2o:draft-child` を外し、generated parent に `trigger:auto-parent` を付けられる。この command は label 変更中に scheduler processing を pause し、A2O が pause した場合は変更成功後だけ resume する。失敗時は確認のため scheduler を paused のまま残す。
- gate closed の decomposition child creation は、空の `success=` を表示せず、`status=gate_closed` と `child_creation_result=not_attempted` を表示する
- multi-repo documentation surfaces: `docs.surfaces` で repo-local docs と integration docs を分けて宣言できる。`docs.authorities` は source-of-truth file が存在する repo slot を指定でき、worker の `docs_context` には surface id、repo slot、role、candidate docs、authority source metadata が含まれる。
- agent-materialized execution では、host agent が具体化した実際の source alias / path から documentation context を解決する。これにより、host agent が workspace を所有する実行経路でも repo-local docs と cross-repo authority を参照できる。
- project prompt composition: `runtime.prompts.repoSlots` は multi-repo task で、task の `repo_slots` / `edit_scope` 順に各 repo slot の prompt / skill addon を合成する。
- worker runtime request と inspection output は、multi-repo task について順序付きの `repo_slots` を出力する。従来の `repo_scope` は single-scope 互換フィールドとして残し、旧 variant lookup 互換のために `both` を表示する場合があるが、multi-repo identity の正本ではない。
- prompt diagnostics / evidence は順序付きの `project_prompt.repo_slots` を出力する。従来の単数 `repo_slot` は single-slot task の場合だけ設定される。
- prompt preview は `a2o prompt preview --phase implementation --repo-slot app --repo-slot lib A2O#123` または `a2o prompt preview --phase implementation --repo-slot app,lib A2O#123` のように、複数 repo slot を指定した multi-repo 合成確認に対応する。
- prompts-only の implementation / review phase に対応する。`runtime.prompts.phases.<phase>` に prompt または skill がある場合、`runtime.phases.<phase>.skill` は省略でき、その phase では no-op の `a2o_core_instruction` layer を出力しない。
- agent server 接続向けの project runtime 調整項目: `runtime.agent_control_plane_connect_timeout`、`runtime.agent_control_plane_request_timeout`、`runtime.agent_control_plane_retry_count`、`runtime.agent_control_plane_retry_delay`
- child / single タスク向けの任意 review gate 項目: `runtime.review_gate.child`、`runtime.review_gate.single`、`runtime.review_gate.skip_labels`、`runtime.review_gate.require_labels`
- 外部 Kanbalone bootstrap 項目: `--kanban-mode external`、`--kanban-url`、`--kanban-runtime-url`
- agent server 接続向けの runtime CLI 上書き: `--agent-control-plane-connect-timeout`、`--agent-control-plane-request-timeout`、`--agent-control-plane-retries`、`--agent-control-plane-retry-delay`
- agent server 接続向けの host agent CLI / runtime profile 項目: `--control-plane-connect-timeout`、`--control-plane-request-timeout`、`--control-plane-retries`、`--control-plane-retry-delay`、`control_plane_connect_timeout`、`control_plane_request_timeout`、`control_plane_retry_count`、`control_plane_retry_delay`
- Kanbalone アダプターと初期化ツール。既定の Kanbalone イメージは `v0.9.28`
- エージェント HTTP ワーカー境界。取得済みジョブの heartbeat を含む
- エージェントが具体化するワークスペース方式
- TypeScript、Go、Python、複数リポジトリタスクテンプレートの参照用プロダクトパッケージ
- GHCR ランタイムイメージタグ: `latest`、`0.5.60`、`sha-*`
- タグリリースでは `latest` も同時に公開する。そのため、公開完了後はリリース版タグと `latest` が同じランタイムイメージを指す前提で確認する。
- ローカルリリース判定: RSpec 全体、release package doctor、local RC host smoke、および runtime 実行 / worker launcher / scheduler / Kanban / env generation 変更時の real-task local RC smoke

## マイグレーション案内

- 既に `runtime.prompts.repoSlots` を定義している project package は、upgrade 前に multi-repo task を確認すること。multi-repo task では `repo_slots` / `edit_scope` 順にすべての repo-slot addon を渡す。以前の release では単数 repo-slot layer だけが適用対象だったため、slot 固有の指示が組み合わさって広すぎる、または衝突する場合がある。その場合は repo slot 単位の child task に分割するか、package prompt を調整する。worker 実行前に `a2o prompt preview --phase implementation --repo-slot app --repo-slot lib <task-ref>` で合成後の instruction を確認する。
- validation を満たすためだけの no-op `runtime.phases.implementation.skill` / `runtime.phases.review.skill` stub を使っている project package は、対応する `runtime.prompts.phases.<phase>` に prompt または skills を定義したうえで stub を削除できる。system prompt だけでは不十分であり、phase skill と対応する phase prompt / skill のどちらも無い場合、`a2o project validate` は引き続き `runtime.phases.<phase>.skill must be provided` で失敗する。
- `a2o runtime start` と `a2o runtime stop` は互換 alias ではなくなった。常駐スケジューラを再開する場合は `a2o runtime resume`、現在の作業後に停止予約する場合は `a2o runtime pause` を使う。削除済みコマンドを実行した場合、A2O は非ゼロで終了し、`migration_required=true` と移行先コマンドを表示する。
- custom worker は review disposition の scope 欄として `review_disposition.slot_scopes` を返す必要がある。0.5.60 の worker result では `review_disposition.repo_scope` を受け付けない。`"repo_alpha"` のような値は `slot_scopes: ["repo_alpha"]` に、複数リポジトリの指摘は対象 slot 名の配列に移行する。保存済み worker result は `a2o worker validate-result --request request.json --result result.json --review-slot-scope <slot>` で検証する。
- SoloBoard 時代の Kanbalone 互換名は削除された。`KANBAN_BACKEND=kanbalone`、`KANBALONE_BASE_URL`、`KANBALONE_API_TOKEN`、`--kanbalone-port`、`A2O_BUNDLE_KANBALONE_PORT`、`A2O_KANBALONE_INTERNAL_URL` を使う。削除済み SoloBoard 入力を使った場合は `migration_required=true` と置き換え先を表示する。
- 同梱 Kanbalone のデータ名は `<compose-project>_soloboard-data` / `soloboard.sqlite` から `<compose-project>_kanbalone-data` / `kanbalone.sqlite` に変わった。旧 volume が存在し、新 volume が存在しない場合、`a2o kanban up` は空の board を作らず `migration_required=true` で停止する。同梱サービスを起動する前に、既存の Kanban data を copy または rename する。
- runtime / agent / worker / root utility 設定の公開 `A3_*` 環境変数 fallback は、`A2O_*` 置き換えがあるものから削除された。`A2O_RUNTIME_IMAGE`、`A2O_COMPOSE_PROJECT`、`A2O_COMPOSE_FILE`、`A2O_RUNTIME_SERVICE`、`A2O_BUNDLE_AGENT_PORT`、`A2O_BUNDLE_STORAGE_DIR`、`A2O_AGENT_PACKAGE_DIR`、`A2O_AGENT_TOKEN`、`A2O_AGENT_TOKEN_FILE`、`A2O_AGENT_CONTROL_TOKEN`、`A2O_AGENT_CONTROL_TOKEN_FILE`、`A2O_AGENT_*`、`A2O_WORKER_*`、`A2O_WORKSPACE_ROOT`、`A2O_ROOT_DIR`、`A2O_ROOT_*` root utility controls を使う。削除済み `A3_*` 入力を使った場合は `migration_required=true` と置き換え先を表示する。
- `worker-runs.json` は activity state source ではなくなった。operator diagnostics、cleanup、rerun readiness、reconcile、watch-summary は `agent_jobs.json` を使う。残存する `worker-runs.json` は `migration_required=true` として報告される。
- 公開 agent package と host launcher artifact は `a2o-agent` / `a2o` 名を使う。リリース archive は `a2o-agent-<version>-<os>-<arch>.tar.gz`、archive 内バイナリは `a2o-agent`、host install は `a2o` と `a2o-<os>-<arch>` のみを書き出す。shell installer は install directory に残った `a3*` ファイルを削除する。旧 package / cache 環境変数名は `migration_required=true` で失敗する。runtime image 内の `a3 agent package ...` も `migration_required=true` で失敗するため、`a2o agent package ...` を使う。
- decomposition command 実行は host launcher と同梱 host agent に依存する。`a2o runtime decomposition investigate`、`propose`、`review` を使う前に、host launcher / shared assets と runtime image を同じ版へ更新すること。古い host launcher のままでは decomposition の host-agent 実行経路を認識できない場合がある。典型的な更新手順は次の通り。
  - release image から新しい launcher を導入する: `docker run --rm -v "$PWD/.work/a2o:/out" ghcr.io/wamukat/a2o-engine:0.5.60 a2o host install --output-dir /out/bin --share-dir /out/share`
  - project の runtime image 参照を `ghcr.io/wamukat/a2o-engine:0.5.60` に更新する
  - decomposition command を実行する前に、新しい image で runtime container を再起動する
- 0.5.60 の decomposition 監視改善を使うには、host launcher と runtime image の両方を更新する必要がある。古い host launcher は 0.5.60 より前の decomposition log fallback 表示のままであり、古い runtime image は watch-summary の新しい stage field を返さない。
- decomposition source ticket を使う外部 Kanbalone 環境は Kanbalone v0.9.28 以降への更新を推奨する。A2O は requirement source ticket から generated implementation work へ `related` relation を書き込み、imported source の provenance には v0.9.28 の `externalReferences` を使う。古い外部 Kanbalone では完全な surface が提供されない。
- `docs.surfaces` を採用する project package は、各 surface の `repoSlot` が repo source として設定されていること、および cross-repo `docs.authorities.*.repoSlot` が source-of-truth file を持つ repo を指していることを確認する。既存の単一 docs surface package には移行作業は不要である。

## 検証範囲

参照用プロダクト群では、単一リポジトリと複数リポジトリのタスク処理を、カンバン、エージェント境界、検証、マージ、親子タスク処理、ランタイム要約表示、`describe-task` の診断、証跡保持まで通して確認する。

## 変更境界

未対応のプロダクト作業は、実装前に A2O カンバンで追跡する。外部仕様の変更が必要な場合は、実装前に owner と協議する。
