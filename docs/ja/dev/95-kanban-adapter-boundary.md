# Kanban Adapter Boundary（kanban adapter の境界）

## Current Contract（現在の contract）

A2O engine は現在、`tools/kanban/cli.py` と互換の command contract を通じて Kanban と通信する。Runtime は次の operations を使う。

- read operations（読み取り operations）: `task-snapshot-list`、`task-watch-summary-list`、`task-get`、`task-label-list`、`task-relation-list`、`task-find`
- write operations（書き込み operations）: `task-transition`、`task-comment-create`、`task-create`、`label-ensure`、`task-label-add`、`task-label-remove`、`task-relation-create`
- text transport: 長い descriptions and comments は shell quoting と argument size 問題を避けるため `--*-file` options を使う。

Command contract は external tooling surface である。内部では Ruby code が orchestration の各所で subprocess call を散らさず、operation client boundary 経由で Kanban にアクセスする。

## Done And Resolved（Done と Resolved）

A2O は automation completion（自動処理の完了）と human confirmation（人間の最終確認）を分けて扱う。

- `status=Done` は、A2O が task の automation flow を完了したことを示す。対象 phase がある場合は implementation、verification、merge の完了を含む。
- SoloBoard の `done=true` / `isResolved=true` は、board 上で人間が task を resolved と確認したことを示す。
- A2O runtime の status publishing は task を `Done` lane へ移すが、SoloBoard の resolved flag は設定しない。
- `task-transition --sync-done-state` は、operator が human-resolved flag も同期したい場合にだけ使う。

そのため SoloBoard snapshot で `status=Done` かつ `done=false` になっていても正常である。Runtime の task selection、watch summary、reporting は lane/status を A2O automation state として使い、`done=false` を merge 失敗や automation 未完了として扱ってはいけない。

## Adapter Structure（adapter 構造）

Kanban access は Ruby operation client boundary を中心に構成する。

1. `tools/kanban/cli.py` は command contract 用の developer/operator CLI である。
2. Engine code は operation-level JSON/text helpers を持つ `A3::Infra::KanbanCommandClient` 経由で Kanban operation を実行する。
3. `SubprocessKanbanCommandClient` は、その boundary の背後にある current production SoloBoard implementation である。
4. 追加 provider implementation は、runtime default になる前に同じ operation-level semantics を維持する必要がある。

## Runtime Python Dependency（runtime の Python dependency）

A2O 0.5.5 は `docker/a3-runtime/Dockerfile` に `python3` を残すが、`python3-venv` は install しない。

現在の runtime には、まだ Engine-owned Python dependency がある。

- Go host launcher は runtime command を `--kanban-command python3` 付きで組み立てる。
- command argv は `a3-engine/tools/kanban/cli.py` を指す。
- Ruby Engine bridge construction はまだ `subprocess-cli` kanban backend を default にしている。
- `SubprocessKanbanCommandClient` は、`KanbanCommandClient` の背後にある唯一の production SoloBoard implementation である。

そのため、subprocess CLI が runtime default である間に runtime image から Python を削除すると、標準の `a2o kanban ...` runtime path が壊れる。

## Current Adapter Boundary（現在の adapter boundary）

`A3::Infra::KanbanCommandClient` は operation-level boundary であり、task source、status publisher、activity publisher、follow-up child writer、snapshot reader が使う。Constructors は `command_argv` を受け取り、`SubprocessKanbanCommandClient` を作成する。そのため、runtime behavior と public CLI arguments は安定する。

## Compatibility Requirements（互換要件）

Native adapter は次を維持しなければならない。

- `Project#123` のような canonical task refs
- duplicate refs がある場合の external task id preference
- `To do`、`In progress`、`In review`、`Inspection`、`Merging`、`Done` の status mapping
- blocked label add/remove behavior
- parent/child tasks 用 relation shapes
- multiline text を含む comment and description file semantics
- JSON object/array shape validation and fail-fast errors

現在の command contract を維持するために、SoloBoard API や public Kanban CLI の変更は不要である。

## Multiline Text Contract（multiline text contract）

Automation は task description と comment を `--description-file`、`--append-description-file`、`--comment-file` のような file-backed option で渡す。Kanban CLI の successful write operation は stdout に JSON だけを返すため、呼び出し側は text scraping ではなく JSON parser で task id/ref を取得する。

`task-create --description-file` と `task-update --description-file` は multiline markdown を `description` に保持する。`task-snapshot-list` は backend response から得られる最良の `description` を含め、dashboard や log 用に single-line preview の `description_summary` も含める。`description_source` は `detail`、`list`、`empty` のいずれかで、本文が detail endpoint、list payload、または未取得のどれに由来するかを示す。`description` が空の場合は、その task の body をどの backend response も返さなかったことを示し、JSON transport failure ではない。
