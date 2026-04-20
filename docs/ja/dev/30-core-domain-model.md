# A2O Core Domain Model

この文書は、A2O の core domain object と責務境界を定義する。

## Model Principles

- Domain object は原則 immutable にする。
- Domain object は product 固有の file path や command を知らない。
- Infrastructure は外部 system を domain object へ変換する。
- Application service は state transition を隠さずに domain rule を orchestrate する。
- Public diagnostics は transient log の再構成ではなく domain state から導出する。

## Task

`Task` は中心となる aggregate root である。

Task が持つもの:

- `ref`
- `kind`
- `status`
- `current_run_ref`
- `parent_ref`
- edit scope
- verification scope

Task status は raw kanban lane ではなく internal scheduler state である。A2O は adapter boundary で kanban lane と internal status を相互変換する。

## Run

`Run` は 1 task phase を 1 回実行する attempt を表す。

Run が持つもの:

- run ref
- task ref
- phase
- workspace kind
- source descriptor
- scope snapshot
- artifact owner
- state
- terminal outcome
- blocked diagnosis summary

1 つの task は複数の run を持てる。現在の task state は active run または latest relevant run を指す。

## Phase

Phase は実行中の work type を表す。

- implementation
- review
- parent review
- verification
- remediation
- merge

Phase transition は domain rule である。CLI 条件分岐の各所へ分散して encode してはならない。

## Scope Snapshot

Scope snapshot は run の edit scope と verification scope を固定する。これにより、run 記録後の kanban label や package 変更で、記録済み evidence の意味が変わらないようにする。

## Source Descriptor

Source descriptor は run source の由来を記録する。

- branch head
- detached commit
- parent integration ref
- live target ref

Workspace materialization と evidence inspection は、どちらもこの descriptor に依存する。

## Artifact Owner

Artifact owner は evidence の所有者を表す。

- single / child task の task-owned evidence
- integration flow の parent-owned evidence

Artifact owner は snapshot version を含み、evidence を source state に結びつける。

## Blocked Diagnosis

Blocked diagnosis は operator action のための structured summary である。Failure は次のような category に分類する。

- configuration error
- workspace dirty
- executor failed
- verification failed
- merge conflict
- merge failed
- runtime failed

## Repositories

Domain repository は次の persistence contract を提供する。

- tasks
- runs
- scheduler state
- scheduler cycles
- evidence and blocked diagnosis read models

JSON と SQLite は、同じ repository contract の背後にある infrastructure choice である。
