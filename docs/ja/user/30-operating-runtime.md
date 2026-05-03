# ランタイムの運用

この文書は、A2O を日常運用するときに使うコマンドと確認すべき状態を説明する。初回セットアップは [10-quickstart.md](10-quickstart.md)、パッケージの作り方は [20-project-package.md](20-project-package.md)、問題対応は [40-troubleshooting.md](40-troubleshooting.md) を読む。

読む目的は、A2O を「一度起動して終わり」ではなく、カンバンを監視し続けるランタイムとして扱うための運用手順を把握することである。通常は常駐スケジューラを使い、状態確認、診断、イメージ更新をこの文書の順に行う。

## ランタイムの構成

A2O の通常運用は、次の 4 つで構成される。

| 構成要素 | 役割 | 主なコマンド |
| --- | --- | --- |
| ホスト用ランチャー `a2o` | ホストからランタイムイメージとインスタンスを操作する | `a2o project bootstrap`, `a2o kanban ...`, `a2o runtime ...` |
| A2O Engine | カンバンタスクを選び、フェーズジョブを作り、結果を記録する | `a2o runtime up`, `a2o runtime resume`, `a2o runtime status` |
| a2o-agent | プロダクト環境でジョブを実行し、Git リポジトリを変更・検証する | `a2o agent install` |
| プロジェクトパッケージ | プロジェクト固有のリポジトリ、スキル、コマンド、フェーズを定義する | `a2o project lint` |

ランタイムインスタンスはプロジェクトパッケージから作る。初期化後、`a2o kanban ...`、`a2o agent install`、`a2o runtime ...` は `.work/a2o/runtime-instance.json` を見つけて同じインスタンスを使う。

```sh
a2o project bootstrap
```

パッケージを標準パス以外に置く場合だけ、明示的に指定する。

```sh
a2o project bootstrap --package ./path/to/project-package
```

## 日常操作

通常は、カンバンを起動し、エージェントを配置し、スケジューラを開始する。

```sh
a2o kanban up
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
a2o runtime up
a2o runtime resume --interval 60s --agent-poll-interval 5s
```

状態確認には次を使う。

```sh
a2o runtime status
a2o runtime watch-summary
a2o runtime logs [task-ref] --follow
a2o runtime clear-logs --task-ref <task-ref>
a2o runtime metrics list --format json
a2o runtime metrics summary --group-by parent
a2o runtime metrics trends --group-by parent
a2o runtime skill-feedback list
a2o runtime skill-feedback propose --format ticket
```

`runtime status` はスケジューラ、ランタイムコンテナ、カンバン、イメージダイジェスト、最新実行の状態を見る。`runtime watch-summary` はタスク一覧の現在位置を見る。`runtime logs` は 1 タスクのフェーズ別ログをまとめて読み、AI raw log があればそれを優先して表示する。`--follow` を付けると現在フェーズの AI raw live log を優先して追い、未対応 worker では従来の live log にフォールバックする。task ref を省略して実行中タスクが 1 件だけなら、`runtime logs --follow` はそのタスクを自動選択する。実行中タスクが複数ある場合は `--index N` で選択する。親タスク ref を指定した場合、`--follow` は実行中の子タスクを優先して選び、親自身を追う場合は `--no-children` を指定する。`runtime metrics list` は保存済みタスクメトリクスを JSON または CSV で export する。`runtime metrics summary` はタスク単位の集計を表示し、`--group-by parent` で親単位の集計にできる。`runtime metrics trends` は rework rate、平均 verification 時間、token-per-line-added、test failure rate、source data が不足している indicator などの derived indicator を表示する。`runtime skill-feedback list` は worker が報告した再利用可能な skill 改善候補を一覧表示し、`--state` / `--target` / `--group` で絞り込みや重複集約ができる。`runtime skill-feedback propose` は候補をチケット本文または draft patch に変換するが、skill ファイルは自動変更しない。`runtime clear-logs` は永続化された分析用ログを明示的に整理するコマンドで、デフォルトは dry-run、実削除は `--apply` 指定時だけである。

特定タスクを深く見る場合は `describe-task` を使う。

```sh
a2o runtime describe-task <task-ref>
```

`describe-task` は実行、フェーズ、ワークスペース、証跡、カンバンコメント、ログの手がかり、skill feedback 要約、エージェント成果物の読み方をまとめて表示する。
不正な worker result によりタスクが blocked になった場合、`describe-task` は worker result schema error を `execution_validation_error=` または `blocked_validation_error=` 行として表示する。`watch-summary --details` でも blocked タスクの詳細行に `validation_error=` が表示される。
stdin-bundle worker が組み込みの補正ループ後も不正な JSON または schema-invalid JSON を返し続けた場合、A2O は worker metadata directory の `invalid-worker-results/latest.json` に invalid-result salvage record を保存し、最新 5 件の salvage record を残す。salvage record には raw または parsed の不正出力、構造化 validation error、task/run/phase、schema name が含まれる。同じ workspace で後続 retry が走る場合、最新 salvage record は worker bundle の `previous_invalid_worker_result` として渡される。不正な result が task state を進めることはない。
Kanbalone が blocked / clarification ラベルの理由メタデータを返す場合、`describe-task` は kanban task セクションにそれを含め、`watch-summary --details` は `kanban_tag_reason=` の詳細行を表示する。通常の `watch-summary` にはこれらの追加行を出さない。
worker がプロダクト仕様の曖昧さや矛盾により安全に続行できない場合は `clarification_request` を返せる。A2O はタスクを `needs_clarification` として保存し、Kanban に `needs:clarification` ラベルを付け、質問・背景・選択肢・影響をコメントに残し、依頼者の回答後にラベル／状態が解除されるまでスケジューラ対象外にする。

prompt / skill / worker command の改善に使うため、A2O は次の分析用 artifact を永続化する。

- `combined-log`
- `ai-raw-log`
- 開始時刻 / 終了時刻 / 所要時間を含む `execution-metadata`

これらの分析用 artifact は、終了済みワークスペースの cleanup とは分離して扱う。

## スケジューラと手動実行

通常運用では常駐スケジューラを使う。

```sh
a2o runtime resume --interval 60s --agent-poll-interval 5s
a2o runtime status
a2o runtime pause
```

`runtime resume` はタスク処理を常駐実行する。`runtime pause` は現在の作業が終わったあとにスケジューラを止め、新しいタスクを拾わない。`runtime status` はスケジューラが動いているか、pause 済みか、ランタイムイメージが期待通りか、最新実行がどう終わったかを確認する。

multi-project installation では、lifecycle command を1 project または全登録 project に対して実行できる。

```sh
a2o runtime resume --project <key>
a2o runtime resume --all-projects
a2o runtime status --all-projects
a2o runtime pause --all-projects
```

`--all-projects` は project ごとに scheduler を1つずつ起動または pause する。各 project 内で同時に動く active task は引き続き最大1件であり、この mode で project 内 task 並列は有効にならない。登録 project ごとの `compose_project` と host `agent_port` は一意である必要があり、衝突する場合は scheduler 起動前に fail する。

すでに実行中のタスクをすぐ止める必要がある場合は、dangerous な強制停止コマンドを使う。

```sh
a2o runtime force-stop-task <task-ref> --dangerous
a2o runtime force-stop-run <run-ref> --dangerous
```

これらのコマンドは、active run を既定で `cancelled` terminal として記録し、task の runtime binding を解除して再度スケジュール可能にし、該当 agent job を stale にし、内部 runtime workspace があればクリーンアップし、runtime 実行プロセスを best-effort で止める。必要な手動変更を保存してから、意図的な運用介入としてだけ使う。

スケジューラの選択基準は、カンバンを正本として次の通り固定する。

- `Resolved` / `Archived` のタスクは選択対象にせず、`watch-summary` にも出さない。
- `Done` は人間が resolve するまで current view に残し、`watch-summary` にも表示する。
- 未解決の kanban blocker があるタスクは runnable にしない。
- `needs:clarification` ラベル付きタスクは `needs_clarification` として取り込み runnable にしない。これは依頼者入力待ちであり、技術的な `blocked` 失敗とは分けて扱う。
- 親子関係による制約と sibling の順序制約は、kanban blocker に加えて適用する。
- 親チケットに子タスクがある場合は、親子を 1 つの選択グループとして扱う。
- 複数の親グループがある場合は、まず親チケットの priority が高いグループを選ぶ。
- 選ばれた親グループの中では、その時点で runnable な子タスクのうち priority が最も高いものを選ぶ。
- 親チケットに付いた未解決 blocker は子タスクにも継承される。親 blocker が残っている間は、その親グループ配下の子タスクは runnable にしない。
- 親が blocked と見える状態は、その親グループの子タスクも selection 対象外であることを意味する。
- 親子グループに属さない runnable 候補が複数ある場合は、kanban の priority が高いものを先に選ぶ。
- priority が同じ場合は task ref で順序を決める。

`runtime run-once` は手動確認や検証用である。スケジューラを使う前に 1 回だけ取り込みたいときや、問題を直した後に再同期したいときに使う。

```sh
a2o runtime run-once
```

コンテナの起動・停止だけを扱う場合は `runtime up` / `down` を使う。これらはスケジューラを開始しない。

```sh
a2o runtime up
a2o runtime down
```

## カンバン運用

カンバンは A2O Engine がタスクを読む入口である。

```sh
a2o kanban up
a2o kanban doctor
a2o kanban url
```

`kanban up` は同梱されたカンバンサービスを起動し、A2O が必要とするレーンと内部ラベルを用意する。利用者は A2O が管理するレーンや内部ラベルをプロジェクトパッケージに手書きしない。

既定は同梱 Kanbalone である。複数の A2O プロジェクトから独立した 1 つの Kanbalone インスタンスへ接続し、プロジェクトごとに別ボードを使いたい場合は、外部モードでランタイムインスタンスを作る。

```sh
a2o project bootstrap --kanban-mode external --kanban-url http://127.0.0.1:3470
```

外部モードでは、利用者が開くボード URL と、必要に応じて Docker コンテナ内のランタイムから到達する URL をランタイムインスタンスへ保存する。コンテナからホスト URL に直接到達できない場合は `--kanban-runtime-url` を指定する。ホスト URL が loopback の場合、明示指定がなければ A2O は `host.docker.internal` を使うランタイム URL を導出する。このモードでは `kanban up`、`kanban doctor`、`runtime status`、`runtime doctor`、`doctor` が外部 endpoint を確認する。`runtime up` は同梱 Kanbalone コンテナを管理せず、A2O ランタイムコンテナだけを起動する。

同じ Compose プロジェクトなら既存ボードを再利用する。Compose プロジェクトや Docker volume が変わると、同じプロダクトでも別ボードに見える。ボードが空に見える場合は、まず `a2o runtime status` と `a2o kanban doctor` でインスタンス設定、Compose プロジェクト、volume を確認する。

## 要求の分解

カンバンチケットが大きな要求であり、実装前に調査して子チケットへ分けたい場合は `trigger:investigate` を使う。`trigger:investigate` が付いた source ticket は、`trigger:auto-implement` が同時に付いていても decomposition domain に属する。source ticket 自体を通常の実装対象として扱うには、先に `trigger:investigate` を外す。source ticket は実装対象ではないため、`repo:*` scope label は不要である。A2O は source ticket を implementation parent ではなく、要求 artifact として扱う。通常運用では、実装は生成された parent / child の task tree 側で進め、実装対象の child ticket に適切な repo label を付ける。

自動 decomposition flow は次の順で進む。

1. A2O が `trigger:investigate` 付きの source ticket を選択する。
2. A2O が source ticket を `In progress` に移動し、プロジェクト所有の investigation command が実行され、調査 evidence を記録する。
3. proposal author が正規化された child-ticket proposal を作る。
4. A2O が source ticket を `In review` に移動し、proposal review が draft child creation に進める状態かを判定する。
5. eligible な proposal から、要求 source ticket とは別の generated implementation parent ticket を `Backlog` に作り、generated parent の description と source ticket への comment に要求 source を記録し、その generated parent の下に `a2o:draft-child` 付きの draft child ticket を `Backlog` に作る。proposal に `parent.title` や `parent.body` が含まれる場合、A2O は generated parent の初回作成時にそれを使い、project 固有の実装計画を parent ticket に持たせる。
6. A2O が source ticket を decomposed として印付けし、`Done` に移動する。

A2O は要求 source ticket から generated implementation parent へ `related` relation も作る。この relation は traceability 専用であり、source ticket を runnable にはしない。また child の `subtask` relation や依存関係の `blocked` relation を置き換えない。外部 Kanbalone 環境では、この decomposition relation 経路のために Kanbalone v0.9.25 以降が必要である。

source ticket が外部 issue から import されたものでも、A2O は source ticket を要求 artifact として残し、generated parent を同じ外部 issue として再 import しない。正規化した remote metadata は child-creation evidence の `source_remote` に残し、Kanbalone v0.9.28 以降では generated parent に non-tracking な `externalReferences[source]` も書き込む。古い外部 Kanbalone endpoint では relation / evidence による traceability を維持し、ticket 本文へ remote metadata をコピーする代わりに child-creation warning を記録する。generated parent や draft child の本文には remote metadata をコピーしないため、worker 入力のノイズを増やさず、出自が必要な場合は relation、generated parent の external reference、または evidence を辿る。

各 stage が完了すると、source ticket に短いコメントが残るため、運用者は Kanban 上で進行を追える。`a2o runtime watch-summary` も `trigger:investigate` の source ticket を `Decomposition` セクションに表示する。まだ evidence がない段階では `state=queued` として表示し、decomposition 実行中は `stage=investigate`、`stage=propose`、`stage=review`、`stage=create_children` のように現在 stage を表示する。active な decomposition source がある場合、scheduler summary は `Scheduler: running` になり、task tree 上の source ticket も running marker で表示される。詳細な evidence は runtime storage 配下の `decomposition-evidence/<task>/` に保存される。`a2o runtime decomposition status <task-ref>` は decomposition evidence の概要を表示し、`a2o runtime describe-task <task-ref>` はより広い task 状態を表示する。

`a2o runtime logs <task-ref>` は decomposition source ticket に対しても利用できる。source ticket に通常の implementation / review log artifact がない場合、decomposition status と evidence path の表示にフォールバックする。`--follow` を指定すると、A2O は decomposition status を polling し、source ticket の decomposition 中に取得できる investigate / propose / review action log を stream 表示する。

draft child は計画用の artifact である。生成された parent の下に `Backlog` で作られ、人間が `trigger:auto-implement` を付けて承認し、さらに実行可能な `To do` lane へ移動するまで runnable にはならない。運用者は承認前に、生成された parent と child の title、body、label、blocker、scope を編集できる。proposal に child の `depends_on` が含まれる場合、A2O は依存先を proposal の `boundary` と生成された `child_key` の両方から解決し、生成された child ticket 間に Kanban の `blocked` relation を作る。`a2o:draft-child` を外すことは任意の metadata 整理であり、label 側の runnable gate は `trigger:auto-implement`、lane 側の gate は運用者による `To do` への移動である。draft child を承認すると、A2O は既定で generated parent に `trigger:auto-parent` と accepted child の `repo:*` label の和集合を付ける。これは元の要求 source ticket には付けない。

project-package の proposal author は、proposal JSON の任意 `parent.title` と `parent.body` で generated parent の内容を制御できる。具体的な proposal shape と例は [90-project-package-schema.md](90-project-package-schema.md#runtime-decomposition) を参照する。

よく使うコマンド:

```sh
a2o runtime decomposition status <task-ref>
a2o runtime decomposition accept-drafts <parent-ref> --child <child-ref> --remove-draft-label
a2o runtime decomposition cleanup <task-ref> --dry-run
a2o runtime decomposition cleanup <task-ref> --apply
```

`accept-drafts` は、1つ以上の draft child を一括で承認するための convenience command である。child に `trigger:auto-implement` を付け、generated parent には既定で `trigger:auto-parent` と accepted child の `repo:*` label の和集合を付ける。child と generated parent の label を変更している間は scheduler processing を pause し、変更 batch が成功した後だけ resume する。scheduler がもともと paused だった場合は paused のままにする。A2O が pause した後に batch が失敗した場合も、確認のため paused のまま残す。child acceptance 後も generated parent を runnable にしたくない場合だけ `--no-parent-auto` を使う。

`runtime.decomposition.investigate.command`、`runtime.decomposition.author.command`、decomposition prompt / template layer などの project package 設定は [90-project-package-schema.md](90-project-package-schema.md#runtime-decomposition) を読む。

## エージェント運用

a2o-agent は、A2O Engine から渡されたジョブをプロダクト環境で実行するバイナリである。標準配置先は `.work/a2o/agent/bin/a2o-agent` である。

```sh
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
```

エージェントが使うワークスペース、具体化されたデータ、ランチャー設定は `.work/a2o/agent/` 配下に閉じる。プロダクトのリポジトリルートに生成されたランタイムファイルが出る状態は避ける。

エージェントがジョブを実行できるように、プロジェクトパッケージの `agent.required_bins` にはプロダクトのツールチェーンと AI ワーカーの実行ファイルを書く。`your-ai-worker` のようなプレースホルダーが残っていると、`a2o doctor` またはランタイム実行で止まる。

## イメージ更新とダイジェスト確認

新しいランタイムイメージを使う前に、確認専用モードで差分を見る。

```sh
a2o upgrade check
a2o runtime image-digest
```

`upgrade check` は pull、再起動、ファイル編集をしない。ホスト用ランチャーのバージョン、初期化済みインスタンス設定、ランタイムイメージのダイジェスト、エージェント配置状態、次に実行すべきコマンドを表示する。

イメージを取得してランタイムを再起動する。

```sh
a2o runtime up --pull
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
a2o doctor
a2o runtime status
```

`runtime image-digest` は、設定済みの固定参照、ローカルの latest 参照、実行中コンテナの参照を比較する。不一致が出た場合は、使うイメージを確認してから `a2o runtime up` で再起動する。

## 診断コマンド

問題があるときは、広い診断から狭い診断へ進む。

| 見たいこと | コマンド |
| --- | --- |
| パッケージ、エージェント、カンバン、ランタイム、イメージをまとめて見る | `a2o doctor` |
| ランタイムコンテナとスケジューラを見る | `a2o runtime status` |
| ランタイム専用の診断を見る | `a2o runtime doctor` |
| カンバンサービスとボードを見る | `a2o kanban doctor` |
| タスク一覧の進行状況を見る | `a2o runtime watch-summary` |
| 1 タスクのログをまとめて見る | `a2o runtime logs <task-ref>` または `a2o runtime logs --follow` |
| 1 タスクの実行 / 証跡 / ログを見る | `a2o runtime describe-task <task-ref>` |
| メトリクスを export する | `a2o runtime metrics list --format json` または `a2o runtime metrics list --format csv` |
| メトリクスを集計する | `a2o runtime metrics summary --group-by parent` |
| メトリクスの傾向を見る | `a2o runtime metrics trends --group-by parent --format json` |
| 再利用可能な skill 改善候補を見る | `a2o runtime skill-feedback list` |
| skill 改善候補を提案本文にする | `a2o runtime skill-feedback propose --format ticket` |

ブロックされたタスク、未整理のリポジトリ、実行コマンドの失敗、検証失敗などの症状別対応は [40-troubleshooting.md](40-troubleshooting.md) を読む。
