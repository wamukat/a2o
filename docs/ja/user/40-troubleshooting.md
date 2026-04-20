# Troubleshooting

この文書は、A2O の実行が止まったときに、どこを見て何を直すかを説明する。

## まず見る command

```sh
a2o doctor
a2o runtime watch-summary
a2o runtime describe-task <task-ref>
```

`a2o doctor` は project package、executor config、required command、repo clean 状態、agent install、kanban service、runtime container、runtime image digest をまとめて確認する。

`watch-summary` は複数 task の現在位置を見る command である。`describe-task` は 1 task の run、evidence、kanban comment、log hint を集約して表示する。

## Error Category

A2O の stderr と kanban comment には `error_category` と次の action が出る。

| Category | 直すもの |
|---|---|
| `configuration_error` | `project.yaml`、executor config、package path、schema |
| `workspace_dirty` | dirty な repo と file を commit / stash / remove する |
| `executor_failed` | executor binary、credentials、required toolchain、worker result JSON |
| `verification_failed` | product tests、lint、dependencies、remediation command output |
| `merge_conflict` | merge conflict または base branch state |
| `merge_failed` | merge target ref と branch policy |
| `runtime_failed` | Docker、compose、runtime process、printed command output |

## Agent 実行ログを見る

Task に agent execution artifact がある場合、`describe-task` は `agent_artifact` と `agent_artifact_read` command を表示する。

```sh
a2o runtime show-artifact <artifact-id>
```

生成AIの raw transcript を A2O 側で見たい場合は、project executor または AI CLI が transcript を stdout / stderr または worker result に書くようにする。A2O はそれを agent execution artifact として保持する。

## Dirty Repo

Dirty repo で fail-fast するのは、A2O が利用者の未保存変更を上書きしないためである。`workspace_dirty` が出たら、diagnostics に出た repo と file list を確認し、必要な変更を commit / stash / remove してから再実行する。

## Blocked Task の復旧

```sh
a2o runtime reset-task <task-ref>
```

`reset-task` は dry-run recovery plan を表示する。Kanban、runtime state、workspace、branch は変更しない。

推奨手順:

1. `a2o runtime describe-task <task-ref>` で blocked reason、evidence、comment、logs を読む。
2. `a2o runtime watch-summary` で関連 task が running ではないことを確認する。
3. configuration、dirty repo、missing command、executor credentials、verification failure、merge conflict などの root cause を直す。
4. workspace / branch に残った手動変更が必要なら commit / patch / discard を明示的に行う。
5. root cause を直してから kanban の `blocked` label を外す。
6. `a2o runtime run-once` を実行するか、resident scheduler に再 pickup させる。

## Kanban が空に見える

`a2o kanban up` は compose project と Docker volume を使う。Compose project が変わると別 volume になり、同じ product でも別 board に見える。

既存 board を使うか、新しい board を作るか、backup / reset するかを決めてから `a2o kanban up` を実行する。
