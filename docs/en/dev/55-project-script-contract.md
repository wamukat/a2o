# Project Script Contract

A2O allows project packages to own product-specific automation. Package scripts may be Ruby, Bash, Go, Python, Node, or another project-local choice. The stable boundary is not the script language; it is the command, environment, request, result, workspace, and evidence contract that A2O provides.

## Responsibilities

A2O owns:

- phase lifecycle and allowed phase names
- kanban task selection and transitions
- workspace materialization and repo slot paths
- worker request/result transport
- evidence publication and merge orchestration
- diagnostic categories and remediation hints

The project package owns:

- product build, test, verification, and remediation commands
- project-specific bootstrap such as local dependency cache preparation
- support repo setup required by that product
- the AI or deterministic executor command selected for implementation and review

Project scripts must not depend on private runtime files such as `.a3/workspace.json`, `.a3/slot.json`, generated `launcher.json`, or internal A3 environment names.

## Phase Command Contract

A2O defines these public phases for package commands:

- `implementation`
- `review`
- `parent_review`
- `verification`
- `remediation`
- `merge`

Implementation, review, and parent review run through the worker protocol. Verification and remediation run as project commands in the materialized workspace. Merge is configured by policy and is executed by A2O; project packages select supported merge behavior rather than implementing a new merge engine.

Executor commands may use these placeholders:

- `{{result_path}}`
- `{{schema_path}}`
- `{{workspace_root}}`
- `{{a2o_root_dir}}`
- `{{root_dir}}`

Verification and remediation commands may use:

- `{{workspace_root}}`
- `{{a2o_root_dir}}`
- `{{root_dir}}`

## Worker Environment

Project worker commands should use these environment variables:

- `A2O_WORKER_REQUEST_PATH`: JSON request bundle for the current worker job.
- `A2O_WORKER_RESULT_PATH`: path where the worker command writes its final JSON result.
- `A2O_WORKSPACE_ROOT`: materialized workspace root for the current job.
- `A2O_ROOT_DIR`: root directory containing A2O runtime support files visible to the worker.
- `A2O_WORKER_LAUNCHER_CONFIG_PATH`: generated launcher config used by the bundled stdin worker.

`A3_*` names are compatibility aliases only. They are not part of the public project script contract.

## Request Contract

The worker request JSON is the source of truth for project scripts. It includes:

- `task_ref`, `run_ref`, and `phase`
- `skill`
- `task_packet.title` and `task_packet.description`
- `slot_paths`, keyed by repo slot alias
- `phase_runtime`, including task kind and verification commands when relevant
- source descriptor and scope snapshot metadata

Scripts should read repo paths from `slot_paths` rather than assuming a workspace directory layout.

## Result Contract

Worker commands write one JSON object to `A2O_WORKER_RESULT_PATH`. Required keys are:

- `task_ref`
- `run_ref`
- `phase`
- `success`
- `summary`
- `failing_command`
- `observed_state`
- `rework_required`

Implementation success also includes `changed_files` keyed by repo slot. Review and parent review may include `review_disposition` according to the worker response schema.

## Cache And Artifacts

Task-local cache and artifact paths are A2O-managed workspace concerns. Project packages may create product-specific cache directories under the materialized workspace, but durable cache policy and evidence retention belong to A2O. If a project needs a new stable cache/artifact discovery helper, add it as an A2O contract before scripts depend on private runtime paths.

## Validation Direction

`a2o doctor`, `a2o project lint`, and `a2o worker validate-result` should flag:

- use of `A3_*` worker environment names in project packages
- direct reads of private `.a3` metadata files
- missing required worker result keys
- executor commands that do not use public placeholders
- verification/remediation commands that require undeclared binaries

The goal is to keep project-specific automation possible while making the boundary stable across A2O releases.
