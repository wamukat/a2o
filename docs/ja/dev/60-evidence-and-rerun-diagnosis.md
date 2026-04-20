# Evidence And Rerun Diagnosis

この文書は、A2O が evidence を記録し、blocked run を診断し、rerun 判断を支援する方法を定義する。

## Goals

- Transient log が消えた後も completed / blocked run を inspect できるようにする。
- Evidence を source descriptor と artifact owner に結びつける。
- Operator が何を直すべきか分かるように failure を分類する。
- 推測せず安全に rerun できるだけの state を保持する。

## Evidence

Evidence record は次を含む。

- task ref
- run ref
- phase
- workspace kind
- source descriptor
- artifact owner
- snapshot version
- command summary
- output artifact references
- terminal outcome

Evidence は runtime-owned である。利用者に generated workspace metadata の直接確認を要求してはならない。

## Artifact Owner

Artifact owner は evidence を所有する task または parent task を識別する。Snapshot version は evidence を source state に結びつける。

Single / child task は通常 task-scoped evidence を所有する。Parent integration flow は parent-scoped evidence を所有できる。

## Blocked Diagnosis

Blocked diagnosis は low-level errors を operator category へ変換する。

- `configuration_error`
- `workspace_dirty`
- `executor_failed`
- `verification_failed`
- `merge_conflict`
- `merge_failed`
- `runtime_failed`

Diagnostics は次を含める。

- category
- short summary
- affected repo or phase
- relevant file list when available
- next action
- `a2o runtime describe-task <task-ref>` と logs への pointer

## Rerun Policy

Rerun が安全なのは、A2O が次を判断できる場合だけである。

- どの task / phase が失敗したか
- どの source descriptor を使ったか
- workspace が clean か、再作成できるか
- previous failure が terminal か retryable か
- previous run の evidence を保持すべきか

Rerun は evidence を黙って上書きしてはならない。新しい attempt は新しい run を作る。

## Operator Inspection

Operator は次から確認を始める。

```sh
a2o runtime watch-summary
a2o runtime describe-task <task-ref>
```

`watch-summary` は multi-task overview を表示する。`describe-task` は 1 task の task state、run state、evidence、kanban comments、log hints を集約する。

## Retention

Terminal workspace cleanup と evidence retention は別である。A2O は disposable workspace を削除しても、run を inspect するために必要な evidence と blocked diagnosis data を保持できる。

Generated state は、internal workspace metadata を除き `.work/a2o/` 配下に置く。
