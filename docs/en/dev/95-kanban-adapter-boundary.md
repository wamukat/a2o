# Kanban Adapter Boundary

## Current Contract

The A2O engine talks to kanban through a command contract compatible with `tools/kanban/cli.py`. Runtime operations include:

- read: `task-snapshot-list`, `task-watch-summary-list`, `task-get`, `task-label-list`, `task-relation-list`, `task-find`
- write: `task-transition`, `task-comment-create`, `task-create`, `label-ensure`, `task-label-add`, `task-label-remove`, `task-relation-create`
- text transport: long descriptions and comments use `--*-file` options to avoid shell quoting and argument size limits

The command contract is the external tooling surface. Internally, Ruby code reaches kanban through an operation client boundary instead of scattering subprocess calls across orchestration code.

## Done And Resolved

A2O distinguishes automation completion from human confirmation.

- `status=Done` means A2O completed the automation flow for the task, including implementation, verification, and merge when those phases apply.
- SoloBoard `done=true` / `isResolved=true` means a human has confirmed the task as resolved in the board.
- A2O runtime status publishing moves tasks to the `Done` lane but does not set the SoloBoard resolved flag.
- `task-transition --sync-done-state` is reserved for operator actions that intentionally synchronize the human-resolved flag.

Therefore a SoloBoard snapshot with `status=Done` and `done=false` is valid. Runtime task selection, watch summary, and reporting must use the lane/status as the A2O automation state and must not treat `done=false` as a failed merge or incomplete automation.

## Adapter Structure

Kanban access is organized around a Ruby operation client boundary:

1. `tools/kanban/cli.py` is the developer/operator CLI for the command contract.
2. Engine code routes kanban operations through `A3::Infra::KanbanCommandClient`.
3. `SubprocessKanbanCommandClient` is the current production SoloBoard implementation behind that boundary.
4. Additional provider implementations must preserve the same operation-level semantics before becoming runtime defaults.

## Runtime Python Dependency

A2O 0.5.5 keeps `python3` in `docker/a3-runtime/Dockerfile`, but does not install `python3-venv`.

The runtime still has an Engine-owned Python dependency:

- the Go host launcher builds runtime commands with `--kanban-command python3`
- the command argv points at `tools/kanban/cli.py`
- Ruby Engine bridge construction still defaults to the `subprocess-cli` kanban backend
- `SubprocessKanbanCommandClient` is still the production SoloBoard implementation behind `KanbanCommandClient`

Removing Python from the runtime image while the subprocess CLI remains the runtime default would break the standard runtime path.

## Current Adapter Boundary

`A3::Infra::KanbanCommandClient` is the operation-level boundary used by task source, status publisher, activity publisher, follow-up child writer, and snapshot reader. Constructors accept `command_argv` and create `SubprocessKanbanCommandClient`, so runtime behavior and public CLI arguments stay stable.

## Compatibility Requirements

Any native adapter must preserve:

- canonical task refs like `Project#123`
- external task id preference when duplicate refs exist
- status mapping for `To do`, `In progress`, `In review`, `Inspection`, `Merging`, and `Done`
- blocked label add/remove behavior
- relation shapes for parent/child tasks
- multiline comment and description file semantics
- JSON object/array shape validation and fail-fast errors

No SoloBoard API or public kanban CLI changes are required to preserve the current command contract.

## Multiline Text Contract

Automation must pass task descriptions and comments with file-backed options such as `--description-file`, `--append-description-file`, and `--comment-file`. The kanban CLI returns only JSON on stdout for successful write operations, so callers should parse the returned task id/ref with a JSON parser instead of scraping text.

`task-create --description-file` and `task-update --description-file` preserve multiline markdown in `description`. `task-snapshot-list` includes the best available `description` and also includes `description_summary`, a single-line preview for dashboards and logs. `description_source` is `detail`, `list`, or `empty` so operators can tell whether the body came from the detail endpoint, the list payload, or was unavailable. An empty `description` means no backend response exposed a body for that task; it is not a JSON transport failure.
