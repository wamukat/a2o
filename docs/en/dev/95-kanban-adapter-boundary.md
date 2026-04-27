# Kanban Adapter Boundary

This document defines the adapter boundary used when A2O Engine reads and writes kanban tasks. In the runtime flow, scheduler task selection, status publication, comments, evidence reporting, and parent/child task relation management all pass through this boundary.

Read this to keep A2O domain state separate from Kanbalone API and CLI details. Kanbalone is the renamed successor of SoloBoard. The public adapter backend name is `kanbalone`; SoloBoard-era backend names are removed compatibility inputs. Kanban is the user-visible task queue, but Engine code should read and write it through an operation-level client that explicitly maps lane names and resolved flags into A2O semantics.

## Current Contract

The A2O engine talks to kanban through a command contract compatible with `tools/kanban/cli.py`. Runtime operations include:

- read: `task-snapshot-list`, `task-watch-summary-list`, `task-get`, `task-label-list`, `task-relation-list`, `task-find`
- read structured metadata when supported: `task-label-reason-list`, `task-event-list`
- write: `task-transition`, `task-comment-create`, `task-create`, `label-ensure`, `task-label-add`, `task-label-remove`, `task-relation-create`, `task-event-create`
- text transport: long descriptions and comments use `--*-file` options to avoid shell quoting and argument size limits

The command contract is the external tooling surface. Internally, Ruby code reaches kanban through an operation client boundary instead of scattering subprocess calls across orchestration code.

Use `KANBALONE_BASE_URL`, `KANBALONE_API_TOKEN`, and `KANBAN_BACKEND=kanbalone` for adapter configuration. SoloBoard-era backend and environment names are removed compatibility inputs; when they are invoked directly, A2O reports `migration_required=true` and the Kanbalone replacement.

## Runtime Kanbalone Modes

A2O supports two runtime instance modes:

- `bundled`: A2O starts and manages the bundled Kanbalone service for the project instance.
- `external`: A2O connects to an existing Kanbalone endpoint and only provisions/checks the configured board.

External mode stores both a user-facing `kanban_url` and an optional `kanban_runtime_url`. The host launcher uses the public URL for operator commands such as `a2o kanban url`; runtime container commands use the runtime URL so Docker networking can target `host.docker.internal` or another reachable service name. The adapter contract remains the subprocess CLI contract above; only the endpoint and lifecycle ownership change.

## Done And Resolved

A2O distinguishes automation completion from human confirmation.

- `status=Done` means A2O completed the automation flow for the task, including implementation, verification, and merge when those phases apply.
- Kanbalone `done=true` / `isResolved=true` means a human has confirmed the task as resolved in the board.
- A2O runtime status publishing moves tasks to the `Done` lane but does not set the Kanbalone resolved flag.
- `task-transition --sync-done-state` is reserved for operator actions that intentionally synchronize the human-resolved flag.

Therefore a Kanbalone snapshot with `status=Done` and `done=false` is valid. Runtime task selection, watch summary, and reporting must use the lane/status as the A2O automation state and must not treat `done=false` as a failed merge or incomplete automation.

## Scheduler Selection Inputs

The kanban adapter provides the inputs used by scheduler selection.

- `status` / lane determines whether the task is part of the current view.
- `Resolved` and `Archived` are excluded from runtime selection and watch-summary.
- `Done` remains part of the current view until a human-resolved transition removes it.
- `priority` is imported as a scheduling input. Higher kanban priority wins.
- `blocking_task_refs` are imported as scheduling blockers. An unresolved blocker prevents runnable selection.
- parent/child relations remain separate from blocker relations and continue to gate parent and sibling progression.
- Parent tickets also define selection groups. When multiple parent groups exist, parent priority decides which group the scheduler considers first.
- Child priority is only compared inside the already selected parent group.
- Blocker relations attached to a parent are inherited by child runnable checks. While a parent blocker remains unresolved, children in that parent group are not runnable.

The adapter boundary must preserve these fields and semantics when reading snapshots or relations. If a future provider omits one of these fields, runtime task selection is no longer compatible with the current contract.

## Adapter Structure

Kanban access is organized around a Ruby operation client boundary:

1. `tools/kanban/cli.py` is the developer/operator CLI for the command contract.
2. Engine code routes kanban operations through `A3::Infra::KanbanCommandClient`, including operation-level JSON and text helpers.
3. `SubprocessKanbanCommandClient` is the current production Kanbalone-compatible implementation behind that boundary.
4. Additional provider implementations must preserve the same operation-level semantics before becoming runtime defaults.

## Runtime Python Dependency

A2O 0.5.37 keeps `python3` in `docker/a3-runtime/Dockerfile`, but does not install `python3-venv`.

The runtime still has an Engine-owned Python dependency:

- the Go host launcher builds runtime commands with `--kanban-command python3`
- the command argv points at `a3-engine/tools/kanban/cli.py`
- Ruby Engine bridge construction still defaults to the `subprocess-cli` kanban backend
- `SubprocessKanbanCommandClient` is still the only production Kanbalone-compatible implementation behind `KanbanCommandClient`

Removing Python from the runtime image while the subprocess CLI remains the runtime default would break the standard `a2o kanban ...` runtime path.

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

No Kanbalone API or public kanban CLI changes are required to preserve the current command contract.

## Reasoned Tags And Structured Events

Kanbalone `v0.9.21` adds optional reason metadata for attached ticket tags and opaque structured ticket events. A2O keeps the same state model: lane/status and current tag presence remain authoritative, and historical events are not used to infer task state.

The adapter exposes these APIs conservatively:

- `task-label-add` accepts optional `--reason` and `--details-json` / `--details-file`. When the connected Kanbalone supports reasoned tag attach, the adapter sends the reason metadata. Older Kanbalone instances fall back to the existing `tagIds` update and silently drop reason metadata.
- `task-label-reason-list` returns current tags with `reason`, `details`, `reason_comment_id`, and `attached_at` when supported. Older Kanbalone instances return the current tag list with null reason fields.
- `task-event-create` writes an opaque structured event when supported. If the API is unavailable, callers must provide `--fallback-comment` or `--fallback-comment-file` so the adapter can preserve a human-readable timeline comment.
- `task-event-list` returns structured events when supported and an empty list when the API is unavailable.

Structured events are an automation log surface, not a replacement for the current status/tag model.

A2O emits structured Kanbalone events for these lifecycle points when the connected adapter supports `task-event-create`:

- `task_started` when a run is started.
- `task_blocked` when a completed run leaves the task blocked.
- `clarification_requested` when a completed run asks for user clarification.
- `task_completed` when a completed run leaves the task done.

The activity publisher always supplies the existing Markdown activity body as the fallback comment. Older Kanbalone instances therefore keep the same human-readable comments even though they do not store structured event rows.

## Multiline Text Contract

Automation must pass task descriptions and comments with file-backed options such as `--description-file`, `--append-description-file`, and `--comment-file`. The kanban CLI returns only JSON on stdout for successful write operations, so callers should parse the returned task id/ref with a JSON parser instead of scraping text.

`task-create --description-file` and `task-update --description-file` preserve multiline markdown in `description`. `task-snapshot-list` includes the best available `description` and also includes `description_summary`, a single-line preview for dashboards and logs. `description_source` is `detail`, `list`, or `empty` so operators can tell whether the body came from the detail endpoint, the list payload, or was unavailable. An empty `description` means no backend response exposed a body for that task; it is not a JSON transport failure.
