# Kanban Adapter Migration

Date: 2026-04-17

## Current Contract

The A2O engine currently talks to Kanban through a command contract compatible with `tools/kanban/cli.py`. The runtime uses these operations:

- read: `task-snapshot-list`, `task-watch-summary-list`, `task-get`, `task-label-list`, `task-relation-list`, `task-find`
- write: `task-transition`, `task-comment-create`, `task-create`, `label-ensure`, `task-label-add`, `task-label-remove`, `task-relation-create`
- text transport: long descriptions and comments use `--*-file` options to avoid shell quoting and argument size issues

The command contract remains the external compatibility surface for existing tooling. The migration target is to stop making the Ruby engine depend on a Python subprocess for every Kanban operation.

## Direction

Use a Ruby operation client boundary first, then move provider implementations behind that boundary.

1. Keep `tools/kanban/cli.py` as the developer/operator compatibility CLI.
2. Route engine code through `A3::Infra::KanbanCommandClient`, which exposes operation-level JSON/text helpers.
3. Keep `SubprocessKanbanCommandClient` as the compatibility implementation while native clients are introduced.
4. Add a Ruby-native SoloBoard client behind the same operation client boundary.
5. After runtime validation proves the native client covers the command contract, switch the runtime default from subprocess CLI to native SoloBoard.
6. Only then revisit `A2O#253` and remove Python from the runtime image if no other runtime-owned path requires it.

## Runtime Python Dependency

Decision for `A2O#253`: keep `python3` and `python3-venv` in `docker/a3-runtime/Dockerfile` for now.

The current runtime still has an Engine-owned Python dependency:

- the Go host launcher builds the runtime command with `--kanban-command python3`
- the command argv points at `a3-engine/tools/kanban/cli.py`
- Ruby Engine bridge construction still defaults to the `subprocess-cli` kanban backend
- `SubprocessKanbanCommandClient` is still the only production SoloBoard implementation behind `KanbanCommandClient`

Therefore removing Python from the runtime image today would break the standard `a2o kanban ...` runtime path even though the Ruby side now has a seam for a native adapter.

The blocker for removal is explicit: add and validate a Ruby-native SoloBoard implementation behind `KanbanCommandClient`, then change the runtime default away from `subprocess-cli`. After that, keep `tools/kanban/cli.py` as a developer/operator compatibility CLI outside the runtime hot path and remove Python from the runtime image if no other runtime-owned command still requires it.

## Ruby Native vs Go Client

Ruby native is the first migration target because the engine owns task selection, status projection, review disposition handling, and evidence publication in Ruby. Keeping the adapter in-process removes JSON-over-stdout parsing, tempfile handoff, and subprocess failure translation from the hot path without introducing a second binary boundary.

Go remains appropriate for the public host launcher and agent, but moving Kanban access to Go would still require the Ruby engine to cross a process boundary or to move more engine orchestration out of Ruby. That is a larger refactor and should wait until the Ruby-native boundary is proven insufficient.

## First Slice

The first implementation slice adds `A3::Infra::KanbanCommandClient` and makes task source, status publisher, activity publisher, follow-up child writer, and snapshot reader depend on that operation client. Existing constructors still accept `command_argv` and create `SubprocessKanbanCommandClient`, so runtime behavior and public CLI arguments do not change.

This gives tests and future adapters a typed seam:

- adapters can be exercised without spawning Python
- subprocess-specific Open3 and tempfile details stay in one class
- existing Python CLI compatibility remains intact

## Compatibility Requirements

Any native adapter must preserve:

- canonical task refs like `Project#123`
- external task id preference when duplicate refs exist
- status mapping for `To do`, `In progress`, `In review`, `Inspection`, `Merging`, and `Done`
- blocked label add/remove behavior
- relation shapes for parent/child tasks
- comment and description file semantics, including multiline text
- JSON object/array shape validation and fail-fast errors

No SoloBoard API or public Kanban CLI changes are required for the first slice.
