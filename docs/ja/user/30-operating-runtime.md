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
a2o runtime logs <task-ref> --follow
a2o runtime clear-logs --task-ref <task-ref>
```

`runtime status` はスケジューラ、ランタイムコンテナ、カンバン、イメージダイジェスト、最新実行の状態を見る。`runtime watch-summary` はタスク一覧の現在位置を見る。`runtime logs` は 1 タスクのフェーズ別ログをまとめて読み、AI raw log があればそれを優先して表示する。`--follow` を付けると現在フェーズの AI raw live log を優先して追い、未対応 worker では従来の live log にフォールバックする。`runtime clear-logs` は永続化された分析用ログを明示的に整理するコマンドで、デフォルトは dry-run、実削除は `--apply` 指定時だけである。

特定タスクを深く見る場合は `describe-task` を使う。

```sh
a2o runtime describe-task <task-ref>
```

`describe-task` は実行、フェーズ、ワークスペース、証跡、カンバンコメント、ログの手がかり、エージェント成果物の読み方をまとめて表示する。

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

スケジューラの選択基準は、カンバンを正本として次の通り固定する。

- `Resolved` / `Archived` のタスクは選択対象にせず、`watch-summary` にも出さない。
- `Done` は人間が resolve するまで current view に残し、`watch-summary` にも表示する。
- 未解決の kanban blocker があるタスクは runnable にしない。
- 親子関係による制約と sibling の順序制約は、kanban blocker に加えて適用する。
- runnable な候補が複数ある場合は、kanban の priority が高いものを先に選ぶ。
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

同じ Compose プロジェクトなら既存ボードを再利用する。Compose プロジェクトや Docker volume が変わると、同じプロダクトでも別ボードに見える。ボードが空に見える場合は、まず `a2o runtime status` と `a2o kanban doctor` でインスタンス設定、Compose プロジェクト、volume を確認する。

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
| 1 タスクのログをまとめて見る | `a2o runtime logs <task-ref>` |
| 1 タスクの実行 / 証跡 / ログを見る | `a2o runtime describe-task <task-ref>` |

ブロックされたタスク、未整理のリポジトリ、実行コマンドの失敗、検証失敗などの症状別対応は [40-troubleshooting.md](40-troubleshooting.md) を読む。
