# Troubleshooting

この文書は、A2O の実行が止まったときに、どこを見て何を直すかを説明する。日常運用 command は [30-operating-runtime.md](30-operating-runtime.md) を読む。

## 最初に見るもの

```sh
a2o doctor
a2o runtime status
a2o runtime watch-summary
a2o runtime describe-task <task-ref>
```

`a2o doctor` は project package、executor config、required command、repo clean 状態、agent install、kanban service、runtime container、runtime image digest をまとめて確認する。

`runtime status` は scheduler と runtime instance の状態を見る。`watch-summary` は複数 task の現在位置を見る。`describe-task` は 1 task の run、phase、workspace、evidence、kanban comment、log hint を集約して表示する。

## 症状別の見方

| 症状 | まず見る command | よくある原因 | 直すもの |
| --- | --- | --- | --- |
| task が進まない | `a2o runtime status` | scheduler stopped、runtime container stopped | `a2o runtime up`、`a2o runtime start` |
| board が空に見える | `a2o kanban doctor` | compose project / Docker volume が変わった | instance config、compose project、volume |
| task が blocked になった | `a2o runtime describe-task <task-ref>` | configuration、dirty repo、executor、verification、merge conflict | 表示された error category の対象 |
| executor が起動しない | `a2o doctor` | `your-ai-worker` placeholder、missing binary、credentials 不足 | `project.yaml`、`agent.required_bins`、AI worker 設定 |
| dirty repo で止まる | `a2o runtime describe-task <task-ref>` | 未保存変更や generated file が残っている | 表示された repo/file を commit / stash / remove |
| verification が失敗する | `a2o runtime describe-task <task-ref>` | product test failure、dependency、format、remediation failure | project command、test、dependency |
| merge できない | `a2o runtime describe-task <task-ref>` | conflict、target ref 変更、policy 不一致 | Git branch、target ref、conflict |
| image が想定と違う | `a2o runtime image-digest` | pinned/local/running image の不一致 | runtime image pin、pull、restart |

## Error category

A2O の stderr と kanban comment には `error_category` と次の action が出る。

| Category | 意味 | 直すもの |
| --- | --- | --- |
| `configuration_error` | project package や executor 設定が不正 | `project.yaml`、package path、schema、placeholder |
| `workspace_dirty` | repo に未保存変更がある | dirty な repo と file |
| `executor_failed` | AI worker または executor command が失敗 | executable、credentials、worker result JSON |
| `verification_failed` | product verification が失敗 | tests、lint、dependencies、remediation command |
| `merge_conflict` | merge conflict が起きた | conflict file、base branch state |
| `merge_failed` | merge policy または target ref で失敗 | merge target、branch policy |
| `runtime_failed` | Docker、compose、runtime process が失敗 | printed command output、Docker state |

## Task の詳細を見る

```sh
a2o runtime describe-task <task-ref>
```

`describe-task` では次を見る。

- `latest_blocked` の phase と summary
- `blocked_error_category`
- workspace と source ref
- evidence の場所
- kanban comment の要約
- `agent_artifact_read` command

Agent artifact がある場合は、表示された command で executor stdout/stderr や worker result を読む。

```sh
a2o runtime show-artifact <artifact-id>
```

生成AIの raw transcript を A2O 側で見たい場合は、project executor または AI CLI が transcript を stdout / stderr または worker result に書くようにする。A2O はそれを agent execution artifact として保持する。

## Dirty repo の直し方

Dirty repo で fail-fast するのは、A2O が利用者の未保存変更を上書きしないためである。

1. `a2o runtime describe-task <task-ref>` で dirty な repo と file を確認する。
2. 必要な変更なら commit する。
3. 一時退避でよいなら stash する。
4. 不要な generated file なら remove する。
5. `a2o doctor` で clean 状態を確認する。

Generated runtime file が product repository root に出ている場合は、project package や agent install path を確認する。A2O generated data は `.work/a2o/` 配下に閉じるのが基本である。

## Blocked task の復旧

```sh
a2o runtime reset-task <task-ref>
```

`reset-task` は dry-run recovery plan を表示する。Kanban、runtime state、workspace、branch は変更しない。

推奨手順:

1. `a2o runtime describe-task <task-ref>` で blocked reason、evidence、comment、logs を読む。
2. `a2o runtime watch-summary` で関連 task が running ではないことを確認する。
3. configuration、dirty repo、missing command、executor credentials、verification failure、merge conflict などの root cause を直す。
4. workspace / branch に残った手動変更が必要なら commit / patch / discard を明示的に行う。
5. root cause を直してから kanban の blocked 状態を解除する。
6. `a2o runtime run-once` を実行するか、resident scheduler に再 pickup させる。

## Kanban が空に見える

`a2o kanban up` は compose project と Docker volume を使う。Compose project が変わると別 volume になり、同じ product でも別 board に見える。

確認するもの:

- `.work/a2o/runtime-instance.json` の compose project
- `a2o runtime status` の kanban / runtime instance 情報
- `a2o kanban doctor` の service / board 情報
- Docker volume 名

既存 board を使うか、新しい board を作るか、backup / reset するかを決めてから `a2o kanban up` を実行する。

## どの command から戻るか

原因を直した後は、広い診断から戻す。

```sh
a2o doctor
a2o runtime status
a2o runtime watch-summary
```

Scheduler が動いていれば、次の interval で task が再 pickup される。すぐ確認したい場合だけ `a2o runtime run-once` を使う。
