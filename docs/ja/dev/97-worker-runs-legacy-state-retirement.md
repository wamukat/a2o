# worker-runs legacy state の退役計画

この文書は、`worker-runs.json` の退役状態と現在の activity evidence 方針を記録する。

`worker-runs.json` は activity state source として退役済みである。operator utility は `agent_jobs.json` から正規化した activity evidence を読む。

## 現在の読み取り箇所

- `lib/a3/operator/activity_evidence.rb`
  - `agent_jobs.json` を読み、queued / claimed / completed agent job を activity record に正規化する。
- `lib/a3/cli.rb`
  - watch-summary は claimed `agent_jobs.json` heartbeat のみを使う。
- `lib/a3/operator/diagnostics.rb`、`cleanup.rb`、`rerun_readiness.rb`、`reconcile.rb`
  - `worker-runs.json` を直接 parse せず、正規化 activity evidence を使う。

## 退役判断

`worker-runs.json` reader / writer を再導入しない。

`worker-runs.json` が残っている場合、diagnostics は `migration_required=true` と置き換え先の `agent_jobs.json` path を表示する。reconcile は stale state を `worker-runs.json` に書き戻さず、`active-runs.json` を整理し、現在の agent job state を activity evidence として扱う。

## 現在の方針

1. runtime activity evidence は `agent_jobs.json` を使う。
2. `worker-runs.json` は削除済み state として扱い、migration が必要なことを明示する。
3. 古い `--worker-runs-file` option 名は、隣接する `agent_jobs.json` の特定と削除済み state の診断のための CLI 互換 surface としてのみ残す。
