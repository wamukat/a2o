# Kanban Adapter Boundary（kanban adapter の境界）

## Current Contract（現在の contract）

A2O engine は現在、`tools/kanban/cli.py` と互換の command contract を通じて Kanban と通信する。Runtime は次の operations を使う。

- read operations（読み取り operations）: `task-snapshot-list`、`task-watch-summary-list`、`task-get`、`task-label-list`、`task-relation-list`、`task-find`
- write operations（書き込み operations）: `task-transition`、`task-comment-create`、`task-create`、`label-ensure`、`task-label-add`、`task-label-remove`、`task-relation-create`
- text transport: 長い descriptions and comments は shell quoting と argument size 問題を避けるため `--*-file` options を使う。

Command contract は existing tooling 用の external compatibility surface として残す。内部改善の target は、Ruby engine がすべての Kanban operation で Python subprocess に依存する状態をやめることである。

## Done And Resolved（Done と Resolved）

A2O は automation completion（自動処理の完了）と human confirmation（人間の最終確認）を分けて扱う。

- `status=Done` は、A2O が task の automation flow を完了したことを示す。対象 phase がある場合は implementation、verification、merge の完了を含む。
- SoloBoard の `done=true` / `isResolved=true` は、board 上で人間が task を resolved と確認したことを示す。
- A2O runtime の status publishing は task を `Done` lane へ移すが、SoloBoard の resolved flag は設定しない。
- `task-transition --sync-done-state` は、operator が human-resolved flag も同期したい場合にだけ使う。

そのため SoloBoard snapshot で `status=Done` かつ `done=false` になっていても正常である。Runtime の task selection、watch summary、reporting は lane/status を A2O automation state として使い、`done=false` を merge 失敗や automation 未完了として扱ってはいけない。

## Direction（方針）

まず Ruby operation client boundary を使い、その後 provider implementations をその boundary の背後へ移す。

1. `tools/kanban/cli.py` は developer/operator compatibility CLI として残す。
2. Engine code は operation-level JSON/text helpers を持つ `A3::Infra::KanbanCommandClient` 経由にする。
3. Native clients を導入する間、`SubprocessKanbanCommandClient` は compatibility implementation として残す。
4. 同じ operation client boundary の背後に Ruby-native SoloBoard client を追加する。
5. Runtime validation により native client が command contract を cover することを確認した後、runtime default を subprocess CLI から native SoloBoard へ切り替える。
6. その後、runtime-owned path が Python を必要としない場合に限って runtime image から Python を削除する。

## Runtime Python Dependency（runtime の Python dependency）

A2O 0.5.1 は `docker/a3-runtime/Dockerfile` に `python3` を残すが、`python3-venv` は install しない。

現在の runtime には、まだ Engine-owned Python dependency がある。

- Go host launcher は runtime command を `--kanban-command python3` 付きで組み立てる。
- command argv は `a3-engine/tools/kanban/cli.py` を指す。
- Ruby Engine bridge construction はまだ `subprocess-cli` kanban backend を default にしている。
- `SubprocessKanbanCommandClient` は、`KanbanCommandClient` の背後にある唯一の production SoloBoard implementation である。

そのため、今 runtime image から Python を削除すると、Ruby 側に native adapter 用の boundary があるとしても、標準の `a2o kanban ...` runtime path が壊れる。

Runtime-owned path は Python virtual environment を作成しない。`tools/kanban/cli.py` は `python3` で直接実行される。したがって、future runtime-owned command が venv を必要とすることを証明しない限り、`python3-venv` は runtime requirement に含めない。

削除の blocker は明確である。`KanbanCommandClient` の背後に Ruby-native SoloBoard implementation を追加して validate し、その後 runtime default を `subprocess-cli` から変更する。その後、`tools/kanban/cli.py` を runtime hot path 外の developer/operator compatibility CLI として残し、他の runtime-owned command が Python を必要としない場合に runtime image から Python を削除する。

## Ruby Native vs Go Client（Ruby native と Go client）

Ruby native を最初の migration target とする。理由は、engine が task selection、status projection、review disposition handling、evidence publication を Ruby で所有しているためである。Adapter を in-process に保つことで、JSON-over-stdout parsing、tempfile handoff、subprocess failure translation を hot path から取り除ける。別 binary boundary も増えない。

Go は public host launcher と agent には適している。一方で Kanban access を Go へ移すと、Ruby engine は process boundary を越える必要が残るか、より多くの engine orchestration を Ruby から移す必要がある。それはより大きな refactor であり、Ruby-native boundary が不十分だと分かるまで待つ。

## Current Adapter Boundary（現在の adapter boundary）

`A3::Infra::KanbanCommandClient` は operation-level boundary であり、task source、status publisher、activity publisher、follow-up child writer、snapshot reader が使う。既存 constructors はまだ `command_argv` を受け取り、`SubprocessKanbanCommandClient` を作成する。そのため、native adapters を導入している間も runtime behavior と public CLI arguments は安定する。

この boundary により、tests and future adapters は typed seam を得る。

- adapters は Python を spawn せずに exercise できる。
- subprocess-specific な Open3 と tempfile の details は 1 class に閉じる。
- 既存の Python CLI compatibility は維持される。

## Compatibility Requirements（互換要件）

Native adapter は次を維持しなければならない。

- `Project#123` のような canonical task refs
- duplicate refs がある場合の external task id preference
- `To do`、`In progress`、`In review`、`Inspection`、`Merging`、`Done` の status mapping
- blocked label add/remove behavior
- parent/child tasks 用 relation shapes
- multiline text を含む comment and description file semantics
- JSON object/array shape validation and fail-fast errors

最初の slice では SoloBoard API や public Kanban CLI の変更は不要である。

## Multiline Text Contract（multiline text contract）

Automation は task description と comment を `--description-file`、`--append-description-file`、`--comment-file` のような file-backed option で渡す。Kanban CLI の successful write operation は stdout に JSON だけを返すため、呼び出し側は text scraping ではなく JSON parser で task id/ref を取得する。

`task-create --description-file` と `task-update --description-file` は multiline markdown を `description` に保持する。`task-snapshot-list` は backend response から得られる最良の `description` を含め、dashboard や log 用に single-line preview の `description_summary` も含める。`description_source` は `detail`、`list`、`empty` のいずれかで、本文が detail endpoint、list payload、または未取得のどれに由来するかを示す。`description` が空の場合は、その task の body をどの backend response も返さなかったことを示し、JSON transport failure ではない。
