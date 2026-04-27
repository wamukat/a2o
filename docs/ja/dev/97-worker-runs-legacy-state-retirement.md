# worker-runs legacy state の退役計画

この文書は、現在の `worker-runs.json` 依存関係と、段階的な退役計画を記録する。

`worker-runs.json` はまだ dead code ではない。`agent_jobs.json` は watch-summary の claimed agent job heartbeat を扱えるが、複数の operator utility は今も `worker-runs.json` を active worker evidence として使っている。

## 現在の読み書き箇所

- `lib/a3/cli.rb`
  - `load_watch_summary_legacy_worker_runs` が `worker-runs.json` を読む。
  - `load_watch_summary_agent_job_runs` が `agent_jobs.json` を読む。
  - watch-summary は両方を merge し、task ごとに新しい heartbeat を採用する。
- `lib/a3/operator/root_utility_launcher.rb`
  - `.work/a3/state/<project>/worker-runs.json` を既定の `--worker-runs-file` として解決する。
- `lib/a3/operator/diagnostics.rb`
  - operator diagnostics 用に worker run state を報告する。
- `lib/a3/operator/cleanup.rb`
  - task artifact を削除する前に worker run state を active reference evidence として扱う。
- `lib/a3/operator/rerun_readiness.rb`
  - worker run record から task ID を解決し、rerun readiness を判定する。
- `lib/a3/operator/reconcile.rb`
  - reconcile 時に worker run record を読む。
  - stale active run を mark した後、更新した worker run record を書き戻す。

## 退役判断

現時点では `worker-runs.json` reader を削除しない。

現在の active-worker evidence の置き換えは未完了である。`agent_jobs.json` は heartbeat 表示用として watch-summary には接続されているが、上記の operator utility にはまだ接続されていない。`agent_jobs.json` 自体はすでに runtime agent job store であり、不足しているのは diagnostics、cleanup、rerun readiness、reconcile が共有できる activity-evidence reader である。これらの安全性を維持するには、共通の active-worker evidence abstraction が必要である。

## 段階的な計画

1. `agent_jobs.json` と `worker-runs.json` の両方を 1 つの正規化モデルに読み込む `AgentActivityStore` reader を導入する。
2. watch-summary、diagnostics、cleanup、rerun readiness、reconcile をその正規化 reader に移す。
3. 新しい runtime write は `agent_jobs.json` だけに寄せ、reader は互換のため `worker-runs.json` も読み続ける。
4. 古い `worker-runs.json` に対する migration または expiry policy を追加する。
5. すべての operator utility が正規化 reader / writer に移り、古い state が migration 済みまたは期限切れになった後で、直接の `worker-runs.json` 読み書きを削除する。

それまでは、`worker-runs.json` は未使用機能ではなく、互換 state source として扱う。
