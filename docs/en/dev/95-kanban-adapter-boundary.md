# Kanban Adapter Boundary

## Current Contract

The A2O engine talks to kanban through a command contract compatible with `tools/kanban/cli.py`. Runtime operations include:

- read: `task-snapshot-list`, `task-watch-summary-list`, `task-get`, `task-label-list`, `task-relation-list`, `task-find`
- write: `task-transition`, `task-comment-create`, `task-create`, `label-ensure`, `task-label-add`, `task-label-remove`, `task-relation-create`
- text transport: long descriptions and comments use `--*-file` options to avoid shell quoting and argument size limits

The command contract remains the external compatibility surface for existing tooling. The internal improvement target is to stop making the Ruby engine depend on a Python subprocess for every kanban operation.

## Done And Resolved

A2O distinguishes automation completion from human confirmation.

- `status=Done` means A2O completed the automation flow for the task, including implementation, verification, and merge when those phases apply.
- SoloBoard `done=true` / `isResolved=true` means a human has confirmed the task as resolved in the board.
- A2O runtime status publishing moves tasks to the `Done` lane but does not set the SoloBoard resolved flag.
- `task-transition --sync-done-state` is reserved for operator actions that intentionally synchronize the human-resolved flag.

Therefore a SoloBoard snapshot with `status=Done` and `done=false` is valid. Runtime task selection, watch summary, and reporting must use the lane/status as the A2O automation state and must not treat `done=false` as a failed merge or incomplete automation.

## Direction

Use a Ruby operation client boundary first, then move provider implementations behind that boundary.

1. Keep `tools/kanban/cli.py` as the developer/operator compatibility CLI.
2. Route engine code through `A3::Infra::KanbanCommandClient`.
3. Keep `SubprocessKanbanCommandClient` as the compatibility implementation while native clients are introduced.
4. Add a Ruby-native SoloBoard client behind the same operation client boundary.
5. After runtime validation proves the native client covers the command contract, switch the runtime default from subprocess CLI to native SoloBoard.
6. Only then remove Python from the runtime image if no other runtime-owned path requires it.

## Runtime Python Dependency

A2O 0.5.0 keeps `python3` in `docker/a3-runtime/Dockerfile`, but does not install `python3-venv`.

The runtime still has an Engine-owned Python dependency:

- the Go host launcher builds runtime commands with `--kanban-command python3`
- the command argv points at `tools/kanban/cli.py`
- Ruby Engine bridge construction still defaults to the `subprocess-cli` kanban backend
- `SubprocessKanbanCommandClient` is still the production SoloBoard implementation behind `KanbanCommandClient`

Removing Python from the runtime image before a native adapter is ready would break the standard runtime path.

## Current Adapter Boundary

`A3::Infra::KanbanCommandClient` is the operation-level boundary used by task source, status publisher, activity publisher, follow-up child writer, and snapshot reader. Existing constructors still accept `command_argv` and create `SubprocessKanbanCommandClient`, so runtime behavior and public CLI arguments stay stable while native adapters are introduced.

## Compatibility Requirements

Any native adapter must preserve:

- canonical task refs like `Project#123`
- external task id preference when duplicate refs exist
- status mapping for `To do`, `In progress`, `In review`, `Inspection`, `Merging`, and `Done`
- blocked label add/remove behavior
- relation shapes for parent/child tasks
- multiline comment and description file semantics
- JSON object/array shape validation and fail-fast errors

No SoloBoard API or public kanban CLI changes are required for the first native-adapter slice.

## Multiline Text Contract

Automation must pass task descriptions and comments with file-backed options such as `--description-file`, `--append-description-file`, and `--comment-file`. The kanban CLI returns only JSON on stdout for successful write operations, so callers should parse the returned task id/ref with a JSON parser instead of scraping text.

`task-create --description-file` and `task-update --description-file` preserve multiline markdown in `description`. `task-snapshot-list` includes the full `description` when the backend exposes it and also includes `description_summary`, a single-line preview for dashboards and logs. An empty `description` means the backend returned no body for that task; it is not a JSON transport failure.
