# プロジェクト内 bounded parallel scheduler

この文書は A2O#317 の Phase B/C 設計を定義する。Phase A は multi-project runtime model で扱っており、1つの A2O installation から project ごとに1 scheduler を動かせるが、各 project 内は従来通り active task 1件のままである。この文書は、1 project 内で bounded parallel execution を行うための設計である。

目的は、独立した task を同時に動かせるようにしつつ、既存の親子順序、blocker、run recovery、merge safety を弱めないことである。

## 1. Scope

最初の project 内 parallel scheduler は保守的にする。

- default behavior は `max_parallel_tasks: 1` と同等のままにする。
- `max_parallel_tasks > 1` のとき、独立した task group の workspace phase を同時実行できる。
- 同じ parent group 内の task は引き続き single-threaded とする。
- parent task とその child task は同時に動かさない。
- merge と shared ref への publish は直列化する。
- decomposition は、別設計が入るまで serial domain のままにする。
- cross-machine distributed scheduling は対象外とする。

## 2. Configuration

user-facing configuration は小さく保つ。

```yaml
runtime:
  scheduler:
    max_parallel_tasks: 2
```

`max_parallel_tasks` は解決済み project 内の active task run 数を数える。default は `1`。

MVP では phase 別、repo 別、parent 別の concurrency 設定を追加しない。実利用で必要性が確認できた場合のみ、後続で追加する。

## 3. Current Limitation

現行 scheduler は逐次実行である。

1. `SchedulerCycleExecutor` が `max_steps` まで loop する。
2. 各 loop で `ExecuteNextRunnableTask` を呼ぶ。
3. `ScheduleNextRun` が `PlanNextRunnableTask` から1件の candidate を受け取る。
4. `StartRun` / `RegisterStartedRun` が run を作り、`task.current_run_ref` を書く。
5. 同じ call stack で phase を同期実行する。

これは active task 1件なら安全だが、parallel claim protocol ではない。

- `PlanNextRunnableTask` は1件だけ返すため、batch 内の conflict filtering ができない。
- `current_run_ref` は run record 保存後に書かれるため、split write によって half-started state が残り得る。
- JSON task storage には claim update 向けの compare-and-swap や file lock がない。
- parent group 排他は persisted running sibling に依存しており、batch planner が sibling を同時選択すると、どちらも persisted running になる前に conflict をすり抜ける。
- merge と implementation publish は shared-ref operation なので明示的な runtime lock が必要である。

## 4. Claim Model

parallel scheduling には、実行開始前の durable claim が必要である。claim と run は別概念とする。claim は「この scheduler process が task slot を所有している」ことを表し、run は「phase execution と evidence が存在する」ことを表す。

task claim record は以下を持つ。

- `claim_ref`
- `project_key`
- `task_ref`
- `phase`
- `parent_group_key`
- `state`: `claimed`, `released`, `stale`
- `claimed_by`
- `claimed_at`
- `heartbeat_at`
- `run_ref`
- `stale_reason`

claim は run 作成前に取得する。scheduler は task/phase の live claim を所有している場合にだけ run を開始できる。run startup が成功したら claim に `run_ref` を紐付ける。

claim acquisition API は backing store ごとに atomic でなければならない。

```ruby
claim_task(task_ref:, phase:, parent_group_key:, claimed_by:, now:)
release_claim(claim_ref:, run_ref: nil)
mark_claim_stale(claim_ref:, reason:)
active_claims
```

SQLite storage では transaction に加えて、active task ref と active parent group key の uniqueness constraint を使う。parent group constraint は、in-process batch planner が conflict を filter していても必要である。別 scheduler command、repair leftover、foreground `run-once` が別 process から claim を作ると、storage 側の拒否がなければ same-group claim を作れてしまうためである。JSON storage では `max_parallel_tasks > 1` を有効にする前に file locking を追加する。追加しない場合、JSON mode は parallel scheduler config を明確な診断で拒否する。

## 5. Conflict Keys

planner は batch を作る間に conflict key を予約する必要がある。既に persisted された running task だけに依存してはいけない。

task conflict key:

- task key: `task:<task_ref>`
- parent group key:
  - parent task: `parent-group:<task_ref>`
  - child task: `parent-group:<topmost_parent_ref>`
  - single task: `single:<task_ref>`
- merge/publish 用 shared-ref key: `shared-ref:<repo_slot>:<target_ref>`

batch selection rule:

- active claim または active run が同じ task key を使っていれば選択しない。
- active claim または active run が同じ parent group key を使っていれば選択しない。
- batch 選択中は、選択済み candidate の key を予約し、後続 candidate が conflict をすり抜けないようにする。
- `SchedulerSelectionPolicy` で既存 ordering を適用してから conflict filtering する。
- blocker と `needs:clarification` は引き続き `RunnableTaskAssessment` で扱う。

## 6. Batch Planner

現行 single-task planner を直接置き換えず、`PlanRunnableTaskBatch` を追加する。`max_parallel_tasks: 1` の compatibility path として `PlanNextRunnableTask` は残す。

input:

- all task assessments
- active runs
- active claims
- `max_parallel_tasks`
- current active slot count

output:

- ordered selected candidates
- skipped conflict diagnostics
- status/watch-summary 用 assessment list

selected batch size は以下とする。

```text
max_parallel_tasks - active_claim_or_run_count
```

available slot が 0 の場合、scheduler は idle ではなく busy と扱う。

## 7. Execution Model

scheduler は selection と execution を分離する。

1. stale run と stale claim を repair する。
2. candidate batch を作る。
3. 選択した task を atomic に claim する。
4. 各 claim に対して run を開始する。
5. bounded worker で phase work を実行する。
6. terminal run completion または stale repair 後に claim を release する。

最初の実装は、1 scheduler process と in-process worker pool でよい。cross-process distributed worker は不要である。

`max_steps` は worker loop tick ではなく terminal phase execution 数として数える。`max_steps` 到達時にまだ active run がある場合、scheduler は新規 claim を止める。foreground `run-once` では開始済み worker の完了だけを待つ。background scheduler loop では同一 process 内の active worker が完了するまで処理を続けてよい。

## 8. Merge and Publish Serialization

merge と implementation publish はどちらも shared ref に触る。task claim system が複数 implementation / verification run を許可していても、runtime lock を使う必要がある。

shared-ref lock は以下を持つ。

- `lock_ref`
- `project_key`
- `operation`: `publish` or `merge`
- `repo_slot`
- `target_ref`
- `run_ref`
- `claimed_at`
- `heartbeat_at`

lock は shared-ref operation の直前に取得し、直後に release する。task は shared-ref lock 待ちの間も task claim を保持できる。status surface では `waiting_for_shared_ref_lock` と表示する。

## 9. Recovery

recovery は以下の partial state を扱う必要がある。

1. claim はあるが run が linked されていない
2. claim はあり run も linked されているが、task に `current_run_ref` がない
3. task に `current_run_ref` はあるが live claim がない
4. run は active だが worker process/job が stale

`RepairRuns` は scheduler repair pass へ拡張し、stale claim の marking と claim/run/task reference の reconcile を扱う。repair result は status と watch-summary で見える必要がある。automatic repair は保守的にする。同じ task または parent group を複数の live record が claim している場合、A2O は推測で直さず、明確な diagnostic で block する。

## 10. Operator Surfaces

status と watch-summary は以下を区別する。

- idle: runnable candidate も active run もない
- busy: active claim/run が configured slot を埋めている
- waiting: candidate はあるが parent group または shared-ref lock と conflict している
- stale: claim または run repair が必要

最低限の追加:

- `runtime status` は `max_parallel_tasks`、active slot count、claim/run refs を表示する。
- `watch-summary --details` は claim age、parent group key、waiting conflict、shared-ref lock holder を表示する。
- default `watch-summary` は compact なままにし、task tree state と active run count だけを表示する。
- `show run` と `show task` は claim ref がある場合に表示する。

## 11. Implementation Breakdown

推奨する child ticket order:

1. `runtime.scheduler.max_parallel_tasks` の config parsing と validation を追加する。
2. durable task claim repository と stale claim diagnostics を追加する。
3. parent-group conflict key と batch runnable planning を追加する。
4. `max_parallel_tasks: 1` の挙動を維持しながら bounded scheduler worker pool を追加する。
5. shared-ref publish/merge serialization lock を追加する。
6. 複数 active run / claim 向けに status/watch-summary/show surface を拡張する。
7. independent task、same-parent exclusion、duplicate-claim prevention、stale claim repair、merge serialization の integration test を追加する。

claim repository、conflict-key batch planner、shared-ref publish/merge lock がすべて入るまで、`max_parallel_tasks > 1` を有効化してはいけない。
