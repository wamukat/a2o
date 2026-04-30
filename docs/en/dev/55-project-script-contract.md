# Project Script Contract

A2O allows project packages to own product-specific automation. Package scripts may be Ruby, Bash, Go, Python, Node, or another project-local choice. The stable boundary is not the script language; it is the command, environment, request, result, workspace, and evidence contract that A2O provides.

Read this when writing or reviewing project scripts that run under A2O. The language and local implementation are project choices, but inputs, outputs, and failure information must be shaped so the Engine can interpret them consistently.

## Runtime Placement

This document defines the contract used after the A2O Engine creates a phase job and `a2o-agent` executes a project command. Project scripts should not infer workspace layout or read generated internal files. They should treat the public environment variables and worker request JSON as the source of truth.

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
- optional metrics collection commands
- the AI or deterministic executor command selected for implementation and review

Project scripts must not depend on private runtime files such as `.a2o/workspace.json`, `.a2o/slot.json`, `.a2o/worker-request.json`, `.a2o/worker-result.json`, generated `launcher.json`, or internal A3 environment names.

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

Metrics collection commands use the same command placeholder set as verification and remediation commands. They run only after successful verification.

## Worker Environment

Project worker, verification, and remediation commands should use these environment variables:

- `A2O_WORKER_REQUEST_PATH`: JSON request bundle for the current worker job.
- `A2O_WORKER_RESULT_PATH`: path where worker commands write their final JSON result.
- `A2O_WORKSPACE_ROOT`: materialized workspace root for the current job.
- `A2O_ROOT_DIR`: root directory containing A2O runtime support files visible to the worker.
- `A2O_WORKER_LAUNCHER_CONFIG_PATH`: generated launcher config used by the bundled stdin worker.

`A3_*` names are compatibility aliases only. They are not part of the public project script contract.

## Request Contract

The worker request JSON is the source of truth for project scripts. It includes:

- `task_ref`, `run_ref`, and `phase`
- `skill`
- `command_intent` for verification and remediation command jobs
- `command_intent=metrics_collection` for metrics jobs
- `task_packet.title` and `task_packet.description`
- `slot_paths`, keyed by repo slot alias
- `phase_runtime`, including task kind and verification commands when relevant
- source descriptor and scope snapshot metadata

Scripts should read repo paths from `slot_paths` rather than assuming a workspace directory layout.
For slot-local remediation, the command working directory may be a repo slot while `A2O_WORKSPACE_ROOT` and `slot_paths` still describe the full prepared workspace.
Do not read private `.a2o/.a3` metadata directly; use `A2O_WORKER_REQUEST_PATH`.

## Metrics Result Contract

Metrics collection commands do not write a worker result file. They print one JSON object to stdout. A2O stores the object as a task metrics record after merging runtime-owned metadata.

Allowed project-owned top-level sections are:

- `code_changes`
- `tests`
- `coverage`
- `timing`
- `cost`
- `custom`

Each section must be a JSON object. If the command includes `task_ref`, `parent_ref`, or `timestamp`, those values must match runtime context; otherwise A2O supplies them. Invalid JSON, unsupported sections, and non-object section values are recorded as metrics diagnostics and do not hide the successful verification result.

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

Implementation success also includes `changed_files` keyed by repo slot. Review and parent review may include `review_disposition` according to the worker response schema. The canonical review disposition scope key is `slot_scopes`, a non-empty array of repo slot names such as `["repo_alpha"]` or `["repo_alpha", "repo_beta"]`; `repo_scope` is not accepted in `review_disposition`.

## Cache And Artifacts

Task-local cache and artifact paths are A2O-managed workspace concerns. Project packages may create product-specific cache directories under the materialized workspace, but durable cache policy and evidence retention belong to A2O. If a project needs a new stable cache/artifact discovery helper, add it as an A2O contract before scripts depend on private runtime paths.

## Validation Direction

`a2o doctor`, `a2o project lint`, and `a2o worker validate-result` should flag:

- use of `A3_*` worker environment names in project packages
- direct reads of private `.a2o/.a3` metadata files
- missing required worker result keys
- executor commands that do not use public placeholders
- verification/remediation commands that require undeclared binaries

Lint output should include the next remediation step. For example, `A3_*` names should point to the matching `A2O_*` variables, `.a2o/.a3` metadata reads should point to `A2O_WORKER_REQUEST_PATH` fields such as `slot_paths`, `scope_snapshot`, and `phase_runtime`, and `launcher.json` references should point back to `project.yaml` phase executor settings.

The goal is to keep project-specific automation possible while making the boundary stable across A2O releases.
