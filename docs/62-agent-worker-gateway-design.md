# Agent Worker Gateway Design

Status: design review target
Date: 2026-04-11

## Goal

Connect the existing A3 worker phase execution path to the HTTP pull agent without changing the worker result contract.

A3 already has two separate contracts:

- `LocalWorkerGateway`
  - writes `.a3/worker-request.json`
  - executes a worker command with `A3_WORKER_REQUEST_PATH`, `A3_WORKER_RESULT_PATH`, and `A3_WORKSPACE_ROOT`
  - reads `.a3/worker-result.json`
  - validates worker result schema and canonicalizes implementation `changed_files`
- agent pull transport
  - stores `AgentJobRequest`
  - lets a local host/dev-env `a3-agent` claim and execute a command
  - uploads logs/artifacts to A3-managed artifact storage
  - records `AgentJobResult`

`AgentWorkerGateway` is the bridge between these contracts. It must not replace worker result semantics with generic command success.

## Non-goals

- Do not make A3 image contain project-specific build/runtime toolchains.
- Do not make the agent understand A3 worker phase semantics directly.
- Do not store host/container local artifact paths in `AgentJobResult`.
- Do not introduce async phase completion yet. The first slice keeps the existing synchronous `worker_gateway.run` interface.

## Current Implementation Facts

- `A3::Application::WorkerPhaseExecutionStrategy` calls `worker_gateway.run(...)` and expects an `A3::Application::ExecutionResult`.
- `A3::Infra::LocalWorkerGateway` owns the worker request/result file protocol and implementation `changed_files` canonicalization.
- `A3::Domain::AgentJobRequest` already carries `working_dir`, `command`, `args`, `env`, `timeout_seconds`, and `artifact_rules`.
- `A3::Infra::AgentHttpPullHandler` currently supports enqueue, claim next, artifact upload, and result submit.
- `A3::Infra::JsonAgentJobStore` already supports `fetch(job_id)`, but the HTTP handler does not expose `GET /v1/agent/jobs/{job_id}` yet.
- The compose validation already proves that an `a3-runtime` control-plane container can send a command job to an `a3-agent` container and receive uploaded result artifacts.

## Proposed Shape

### HTTP Control Plane Client

Add an A3-side client for the control-plane API:

- `enqueue(request) -> AgentJobRecord`
- `fetch(job_id) -> AgentJobRecord`

The existing agent-side `A3::Agent::HttpControlPlaneClient` is intentionally not reused because its responsibility is polling and result upload from the agent runtime. The gateway-side client is an A3 control-plane client and should expose enqueue/fetch semantics.

### Job Inspection Endpoint

Add:

```text
GET /v1/agent/jobs/{job_id}
```

Response:

```json
{
  "job": {
    "request": {},
    "state": "queued|claimed|completed",
    "claimed_by": "agent-name",
    "claimed_at": "timestamp",
    "result": {}
  }
}
```

This endpoint is required for the first synchronous gateway slice. Without it, `AgentWorkerGateway#run` cannot know when the agent has completed the command.

### Shared Worker IO

`AgentWorkerGateway#run` should keep the same worker IO as `LocalWorkerGateway`:

1. Remove stale `.a3/worker-result.json`.
2. Write `.a3/worker-request.json`.
3. Enqueue an `AgentJobRequest` with:
   - `working_dir`: `workspace.root_path`
   - `command` and `args`: the configured worker command and arguments
   - `env`:
     - `A3_WORKER_REQUEST_PATH`
     - `A3_WORKER_RESULT_PATH`
     - `A3_WORKSPACE_ROOT`
   - `phase`: `run.phase`
   - `source_descriptor`: `run.source_descriptor`
   - `runtime_profile`: configured runtime profile
4. Poll `GET /v1/agent/jobs/{job_id}` until completed or timeout.
5. Read `.a3/worker-result.json`.
6. Build the final `ExecutionResult` using the same worker response validation as `LocalWorkerGateway`.

The first slice only supports an explicit `same-path` shared workspace profile. The A3 process cannot prove that a host/container agent sees the same path unless the local runtime profile declares that contract. Therefore `agent-http` must require an explicit opt-in such as `--agent-shared-workspace-mode same-path`; without it the gateway fails before enqueueing. Later slices may add mount mapping or agent-side workspace materialization.

### Result Semantics

Command success is not enough. The final phase result must come from worker result semantics:

- If the agent command fails and no worker result exists, return an `ExecutionResult` based on `AgentJobResult`.
- If a worker result exists, validate it and return the worker-provided `ExecutionResult`.
- If the worker result schema is invalid, return the same invalid-worker-result shape as `LocalWorkerGateway`.
- For successful implementation, canonicalize `changed_files` from the workspace, not from the worker payload.

This is intentionally stricter than `LocalWorkerGateway`: if the agent command succeeds but `.a3/worker-result.json` is missing, the phase fails as `invalid_worker_result`. `LocalWorkerGateway` can fall back to the command runner result for legacy local commands; the agent path is only for A3 worker protocol commands.

To avoid duplicating private `LocalWorkerGateway` logic, extract shared worker protocol handling into an internal collaborator:

```text
A3::Infra::WorkerProtocol
```

Responsibilities:

- result path calculation
- worker request writing
- worker result loading
- worker result validation
- worker result to `ExecutionResult`
- implementation `changed_files` canonicalization

Then `LocalWorkerGateway` and `AgentWorkerGateway` both use the same implementation.

### CLI Surface

Extend worker gateway options:

```text
--worker-gateway local|agent-http
--agent-control-plane-url URL
--agent-runtime-profile VALUE
--agent-shared-workspace-mode same-path|agent-materialized
--agent-workspace-root PATH
--agent-source-path ALIAS=PATH
--agent-required-bin VALUE
--agent-job-timeout-seconds N
--agent-job-poll-interval-seconds N
```

Rules:

- default remains `local`
- `agent-http` requires `--agent-control-plane-url`
- `agent-http` requires `--agent-shared-workspace-mode same-path` or `agent-materialized`
- `agent-http` talks to an already running `a3 agent-server`; it does not start the control-plane server itself
- `agent-http` still requires a worker command unless using the skill name as command is explicitly intended
- `agent-http` treats `--worker-command` as an executable and `--worker-command-arg` as argv entries; shell expressions must be passed explicitly as `--worker-command sh --worker-command-arg -lc --worker-command-arg '...'`
- invalid combinations fail during CLI option validation

### Same-Path Gateway Validation

Status: implemented in `spec/a3/infra/agent_worker_gateway_spec.rb`.

Add a focused validation that proves the full bridge:

1. Start `a3 agent-server` with JSON job store and artifact store.
2. Prepare a temporary workspace containing a minimal worker script.
3. Run `AgentWorkerGateway#run` in one thread/process.
4. Run one `a3-agent` job against the server.
5. Assert the returned `ExecutionResult` came from `.a3/worker-result.json`.
6. Assert uploaded combined log artifact exists.

This is intentionally smaller than Portal full verification. Portal full verification should be a later slice after the gateway contract is stable.

### Agent-Materialized Gateway Validation

Status: implemented as `agent-go/scripts/validation-materialized-agent-gateway.sh`.

Add a focused validation that proves the real A3-side materialized bridge:

1. Start `a3 agent-server` with JSON job store and artifact store.
2. Prepare a tiny clean local Git source repository.
3. Run `AgentWorkerGateway#run` in `agent-materialized` mode in a background Ruby process.
4. Run one Go `a3-agent` process with `--workspace-root` and `--source-alias`.
5. Assert the gateway exits successfully from `AgentJobResult.worker_protocol_result`.
6. Assert the worker payload intentionally lied about `changed_files`, and A3 replaced it with descriptor-derived canonical `changed_files`.
7. Assert descriptor evidence for source alias, checkout mode, requested ref, access, dirty state, and changed files.
8. Assert the reserved `worker-result` artifact exists.
9. Assert `cleanup_after_job` removed the materialized workspace and did not leave a Git worktree registration.

This validation uses `sh` as the worker command and does not invoke Portal-specific runtime, Maven, scheduler canaries, or full verification. Its purpose is only to validate the control-plane, Go agent materializer, worker protocol transport, and A3 gateway parsing boundary.

### Agent-Materialized Verification Command Validation

Status: implemented as `agent-go/scripts/validation-materialized-command-runner.sh`.

`VerificationExecutionStrategy` can now use `AgentCommandRunner` through CLI option `--verification-command-runner agent-http`. This keeps verification as command execution, not worker protocol execution, while moving the actual process execution to the configured `a3-agent` runtime.

The focused validation proves:

1. A3 enqueues a verification command job through the HTTP control plane.
2. Go `a3-agent` materializes the requested repo slot from `source_alias`.
3. The materialized workspace includes `.a3/workspace.json` and per-slot `.a3/slot.json` metadata needed by Portal verification scripts.
4. The command exits through the agent result contract and uploads the combined log into A3-managed artifact storage.
5. `cleanup_after_job` removes the agent-owned Git worktree registration.

This validation still avoids Maven / NullAway. Portal full verification is the next slice that reuses the same command runner with project runtime dependencies installed on the agent side.

### CLI Bundle Validation

Status: historical Docker dev-env validation was implemented as retired Portal runtime task (agent-worker-gateway-validation). 2026-04-13 の配布整理で Docker agent image と同 task は削除し、現行確認は host-local `a3-agent` と scheduler run-once に寄せる。

Add a root-level bundle validation that proves the operator CLI path can use `agent-http`:

1. Start `a3-runtime` and `soloboard` through the existing compose bundle.
2. Bootstrap SoloBoard board/lane/tag surface.
3. Start `a3 agent-server` inside `a3-runtime`.
4. Create a small SoloBoard task with `repo:starters` and `trigger:auto-implement`.
5. Run `bin/a3 execute-until-idle` inside `a3-runtime` with:
   - `--worker-gateway agent-http`
   - `--agent-control-plane-url http://127.0.0.1:<port>`
   - `--agent-shared-workspace-mode same-path`
   - `--max-steps 1`
   - `--worker-command sh`
   - `--worker-command-arg -lc`
   - `--worker-command-arg <inline worker-result writer>`
6. Run the compose `a3-agent` service against `http://a3-runtime:<port>` until the gateway process finishes.
7. Assert:
   - gateway output reports executed work
   - the agent job is completed
   - the task reached `Inspection` after the single implementation step
   - combined log artifact exists

This validation must remain separate from Portal full verification. It validates the control-plane/agent/worker-gateway CLI wiring only; Maven, Java, Ruby worker scripts, NullAway, and full Portal verification stay in later slices. Docker-distributed agent images are no longer part of the release surface; the Go `a3-agent` is installed as a release binary on the host or inside a project-owned dev-env.

Operational constraint: the gateway command blocks while waiting for the agent job, so the validation must run the gateway in the background, then run one or more `a3-agent` single-job executions, then wait for the gateway process and fail with captured `server_log`, `gateway_log`, and `agent_log` if it does not exit. Use a dedicated validation storage directory under `/workspace/.work/...`, not the regular bundle validation storage, because the first slice requires the A3-prepared workspace path to be visible at the same path from both `a3-runtime` and `a3-agent`.

### CLI Bundle Verification Validation

Status: historical Docker dev-env verification validation was implemented as retired Portal runtime task (agent-verification-validation). 2026-04-13 の配布整理で同 task は削除し、host-local `a3-agent` 経路を正規確認にする。

This validation proves the operator CLI path can run `run-verification --verification-command-runner agent-http` through the compose `a3-agent` service. The compose service intentionally uses the Portal dev-env agent image, not the generic Go-only image, because this path executes project commands (`ruby "$A3_ROOT_DIR/scripts/a3-projects/portal/inject/portal_remediation.rb"` and `ruby "$A3_ROOT_DIR/scripts/a3-projects/portal/inject/portal_verification.rb"`). The validation uses a small generated repo with a Taskfile to avoid Maven/NullAway cost while still exercising the real Portal remediation/verification script shape.

The validation asserts:

1. A SoloBoard task reaches `Inspection` after a local implementation worker phase.
2. A verification run is started with the canonical `refs/heads/a3/work/<task>` source ref.
3. Remediation and verification are both enqueued as agent command jobs.
4. The Go agent materializes the repo slot, writes `.a3/workspace.json` and `.a3/slot.json`, executes both commands, uploads combined logs, and cleans up the worktree registration.
5. A3 completes the verification run and transitions the task to `Merging`; the validation then moves the synthetic task to `Done` as cleanup.

Portal single-repo / parent full verification is now covered by host-local `a3-agent` scheduler and parent-topology validation. Historical Docker dev-env tasks (`agent-full-verification-validation`, `agent-ui-verification-validation`, `agent-parent-topology-validation`) were removed from the release surface after proving the protocol path.

Uploaded agent artifacts are retained in the A3-managed artifact store and can be cleaned independently from workspace cleanup. `a3 agent-artifact-cleanup` applies retention by artifact class using metadata/blob mtimes, with separate TTLs for `diagnostic` and `evidence` artifacts, optional count caps (`--diagnostic-max-count` / `--evidence-max-count`), optional size caps (`--diagnostic-max-mb` / `--evidence-max-mb`), and a `--dry-run` mode for operator inspection. The Portal runtime exposes the same command as retired Portal runtime task (agent-artifact-cleanup).

## Failure Policy

- Missing or unsupported shared workspace mode: fail before enqueue with `observed_state=agent_workspace_unavailable`.
- Enqueue failure: fail with `failing_command=agent_job_enqueue`.
- Poll timeout: fail with `failing_command=agent_job_wait` and include job id/state diagnostics.
- Completed failed agent job without worker result: fail from `AgentJobResult` exit status and uploaded log references.
- Completed successful agent job without worker result: fail as `invalid_worker_result`; command success alone must not complete an A3 worker phase.
- Verification command agent job failure: fail the verification phase with `failing_command=<verification command>` and include `agent_job_result` upload references in diagnostics.

## Security Boundary

The HTTP pull transport is local-first. It is designed for A3, SoloBoard, and `a3-agent` running on the same host or in the same compose/dev-env network. It is not a central A3 server protocol for remote multi-agent pools.

As a minimum local hardening step, the control plane and agents support optional bearer tokens. A3 `agent-server` accepts an agent token (`--agent-token`, `--agent-token-file`, `A3_AGENT_TOKEN`, `A3_AGENT_TOKEN_FILE`) for agent-side pull/upload/result endpoints and an optional control token (`--agent-control-token`, `--agent-control-token-file`, `A3_AGENT_CONTROL_TOKEN`, `A3_AGENT_CONTROL_TOKEN_FILE`) for A3-side enqueue/fetch endpoints. If no control token is configured, control endpoints fall back to the agent token for local/backward-compatible operation. Go `a3-agent` reads profile `agent_token_file` / `agent_token`, `A3_AGENT_TOKEN_FILE`, `A3_AGENT_TOKEN`, `-agent-token-file`, or `-agent-token`; A3-side `agent-http` gateway clients use the control token options and fall back to agent token options when no control token is configured. When configured, all pull API calls must include `Authorization: Bearer <token>`. Prefer token files for service manager / container operation so the token is not exposed through process arguments. Long-running `a3-agent` and `a3 agent-server` reload token files for each request, so local token replacement can be performed by atomically replacing the token file without restarting the process.

Client-side transport errors are intentionally redacted: Ruby and Go control-plane clients report operation name and HTTP status only, not raw response bodies. This keeps unexpected proxy/server bodies, malformed job payloads, and environment values out of local exception strings while preserving enough status for operator diagnosis.

Transport policy is fail-fast at the URL boundary. Loopback URLs (`127.0.0.1` / `localhost`) and single-label Docker service names such as `http://a3-runtime:7393` are allowed as local topology. Remote `http://` URLs are rejected by default in the Go runtime profile and Ruby `agent-http` gateway setup. Remote deployment, TLS termination, remote worker identity, capability scheduling, and cross-machine artifact routing are out of scope for the current runtime; the explicit insecure-remote opt-in is diagnostic-only.

## Agent-Owned Workspace Materialization

Status: design review target.

The first `AgentWorkerGateway` slice still uses A3-prepared workspaces and a `same-path` mount. That is intentionally temporary. The target architecture is that the agent runtime owns checkout/worktree creation, dirty check, cleanup, and quarantine on the filesystem where commands run.

The same ownership applies to project repo mutation. In Docker + host/dev-env agent mode, A3 Engine is a control plane only: it creates `workspace_request` / future publish-merge requests, validates returned descriptors and artifacts, and updates task/run state. It must not create, checkout, commit, merge, publish, cleanup, or quarantine project-repo worktrees on behalf of the agent. Ruby `local_*` Git adapters are legacy direct/local compatibility surfaces, not the primary Docker distribution path.

### Current Gap

`AgentJobRequest` currently contains:

- `source_descriptor`
- `working_dir`
- `command`
- `args`
- `env`
- `artifact_rules`

This is enough for a same-path command job, but not enough for agent-owned materialization. The agent cannot know:

- which repo slots are required
- where each repo source comes from
- which ref should be checked out per slot
- whether the workspace should be reused or forced fresh
- whether a slot is editable or read-only
- how to report dirty state per slot before and after execution
- how cleanup/quarantine should be handled

### Proposed Contract Addition

Add an optional `workspace_request` object to `AgentJobRequest`.

```json
{
  "workspace_request": {
    "mode": "agent_materialized",
    "workspace_kind": "ticket_workspace",
    "workspace_id": "Portal-123-ticket",
    "freshness_policy": "reuse_if_clean_and_ref_matches",
    "cleanup_policy": "retain_until_a3_cleanup",
    "topology": {
      "kind": "parent_child",
      "parent_ref": "Portal#122",
      "child_ref": "Portal#123",
      "parent_workspace_id": "Portal-122-parent",
      "relative_path": "children/Portal-123/ticket_workspace"
    },
    "slots": {
      "repo_alpha": {
        "source": {
          "kind": "local_git",
          "alias": "member-portal-starters"
        },
        "ref": "refs/heads/a3/work/Portal-123",
        "checkout": "worktree_branch",
        "access": "read_write",
        "sync_class": "eager",
        "ownership": "edit_target",
        "required": true
      }
    }
  }
}
```

Rules:

- `workspace_request` is optional while same-path gateway remains supported.
- If absent, agents keep current behavior and execute `working_dir` directly.
- If present with `mode=agent_materialized`, `working_dir` is deprecated and ignored for materialization. The agent places `workspace_id` under its configured runtime-profile workspace root unless an explicit topology overrides the relative placement.
- For child tasks, A3 emits `topology.kind=parent_child`. The agent materializes the child workspace under `<agent workspace root>/<parent_workspace_id>/<relative_path>` and rejects absolute paths or `..` escapes. This keeps child ticket workspaces physically under the parent workspace while preserving branch/ref ownership in each repo slot.
- The agent must include accepted topology in `AgentWorkspaceDescriptor.topology` and workspace metadata so Engine cleanup/reconcile can trace parent/child workspace relation.
- The agent must materialize all `required=true` slots before running the command.
- For `local_git` sources, `source.alias` resolves through the agent runtime profile to a local project repo. The agent must create the slot as a dedicated branch worktree using `git worktree add --force <slot_path> <branch>`.
- The agent must write worker protocol env paths under the materialized workspace root.
- A3 must verify `AgentWorkspaceDescriptor` against `workspace_request` after job completion.
- Job payload must not choose arbitrary agent filesystem roots. The writable workspace root is agent configuration, not A3 job input.

### Workspace Descriptor Shape

`AgentWorkspaceDescriptor.slot_descriptors` should include enough evidence for A3 to validate the workspace:

```json
{
  "repo_alpha": {
    "runtime_path": "/agent/workspaces/Portal-123-ticket/repo-alpha",
    "source_kind": "local_git",
    "source_alias": "member-portal-starters",
    "checkout": "worktree_branch",
    "requested_ref": "refs/heads/a3/work/Portal-123",
    "branch_ref": "refs/heads/a3/work/Portal-123",
    "resolved_head": "abc123",
    "dirty_before": false,
    "dirty_after": true,
    "access": "read_write",
    "sync_class": "eager",
    "ownership": "edit_target"
  }
}
```

Validation rules:

- every required slot in `workspace_request.slots` must appear in `slot_descriptors`
- descriptor `runtime_path` must be non-empty
- descriptor `resolved_head` must be non-empty for git-backed slots
- `dirty_before` must be `false` unless the job explicitly allows dirty input
- source kind / source alias / requested ref / access must match the request

Dirty input policy for the first materializer slice: the agent hard-fails before command execution if a prepared/reused workspace has dirty input. It returns `JobResult.status=failed` with workspace descriptor evidence. A3 should not rely on running the command and deciding later.

### First Implementation Slice

Do not move full Portal execution yet. Split implementation into three commits:

1. Contract only: implemented.
   - Add Ruby domain model for `AgentWorkspaceRequest`.
   - Add optional `workspace_request` to `AgentJobRequest` and persisted JSON.
   - Add Go contract structs for `workspace_request`.
   - Add roundtrip tests.
2. Materializer unit: implemented.
   - Add agent-side materializer for `local_git` alias + `worktree_branch`.
   - Materializer API has `prepare` and `cleanup` so tests and validation can remove worktrees deterministically.
   - Use agent config to resolve source aliases and workspace root.
3. Worker protocol transport contract: implemented.
   - Add an agent-owned way to carry the worker request into the materialized workspace.
   - Add an agent-owned way to carry the worker result back to A3 without relying on same-path filesystem reads.
4. HTTP validation: implemented.
   - Add an HTTP validation where `AgentJobRequest` has `workspace_request`, the agent creates the worktree, writes worker protocol files under the materialized workspace root, runs `sh`, uploads the worker result evidence, and returns `AgentWorkspaceDescriptor`.
5. Gateway materialized-mode internal branch: implemented.
   - `WorkerProtocol#request_form` exposes the same payload that same-path mode writes to `.a3/worker-request.json`.
   - `AgentWorkerGateway` can accept an injected `workspace_request_builder` and enqueue `workspace_request` + `worker_protocol_request`.
   - The mode is not exposed through CLI/runtime config yet.
   - Successful implementation uses agent-returned slot `changed_files` evidence as canonical input after validating it against `workspace_request`.
6. CLI bridge for materialized mode: implemented.
   - A3 CLI accepts `--agent-shared-workspace-mode agent-materialized`.
   - A3 CLI accepts `--agent-source-alias SLOT=ALIAS`.
   - Runtime job payload carries aliases only; agent filesystem paths stay in agent runtime configuration.
7. End-to-end gateway materialized validation: implemented.
   - `agent-go/scripts/validation-materialized-agent-gateway.sh` proves the real `AgentWorkerGateway` path against the Ruby control plane and Go agent.
   - The validation intentionally mismatches worker-reported `changed_files` and verifies A3 canonicalizes from `AgentWorkspaceDescriptor`.

The next implementation step is runtime package wiring beyond the explicit CLI bridge. Directly deriving `workspace_request` from A3-local `PreparedWorkspace#slot_paths` would weaken the host/dev-env boundary; source aliases and agent workspace roots must come from runtime configuration.

### Worker Loop Integration With Agent-Owned Workspace

The Go agent worker loop should have two execution modes:

- If `workspace_request` is absent, keep the existing command job behavior. Execute `working_dir` directly, upload artifacts from `working_dir`, and report a single `primary` slot descriptor.
- If `workspace_request.mode=agent_materialized`, prepare the workspace through the agent-side materializer before command execution. The command working directory becomes the prepared workspace root, and artifact rules are evaluated relative to that root.

Materialization failure is a completed failed job, not a claimed job that never reports. The agent must submit `JobResult.status=failed`, `exit_code=1`, a diagnostic combined log, and any available workspace descriptor evidence.

The worker protocol needs one additional transport slice before the materialized mode can replace `same-path`:

- A3 must not pre-write `.a3/worker-request.json` into an A3-local workspace when the agent owns the workspace.
- The job request must carry the worker protocol request payload, or a named artifact the agent can fetch, so the agent can write `.a3/worker-request.json` under the prepared workspace root immediately before command execution.
- The agent must set `A3_WORKER_REQUEST_PATH`, `A3_WORKER_RESULT_PATH`, and `A3_WORKSPACE_ROOT` to paths under the prepared workspace root, overriding any stale values in `env`.
- The agent must return `.a3/worker-result.json` to A3 as first-class evidence after command execution. A3 must build the final phase `ExecutionResult` from that worker result, not from generic command success.
- The first implementation returns the worker result in two forms: a bounded inline `worker_protocol_result` field in `AgentJobResult` for synchronous phase parsing, and an uploaded artifact with reserved role `worker-result` for durable evidence. The initial inline payload limit is 1 MiB; invalid or oversized worker result JSON is still uploaded as evidence, but omitted from the inline field.

Configured `artifact_rules` in materialized mode are evaluated relative to the prepared workspace root after worker-result capture. Cleanup must occur only after worker-result capture, configured artifact uploads, and result submission attempts complete. For the first validation, use a cleanup policy that allows deterministic test cleanup while still preserving enough uploaded evidence for A3 to parse the worker result.

`AgentWorkerGateway` materialized mode parses completed worker results through `AgentJobResult.worker_protocol_result`. For successful implementation, A3 derives canonical `changed_files` from `AgentWorkspaceDescriptor.slot_descriptors[*].changed_files`, validates the descriptor against `workspace_request`, records worker-payload mismatches in diagnostics, and writes the descriptor-derived value to the final response bundle. A3 treats agent `runtime_path` values as diagnostics only and does not read them.

The first operator-facing bridge is explicit CLI configuration, not implicit inference from `--repo-source`:

- A3 CLI accepts `--agent-shared-workspace-mode agent-materialized` only with `--agent-source-alias SLOT=ALIAS`.
- A3 job payload contains both `workspace_request.slots.*.source.alias` and optional `agent_environment.source_paths[alias]`.
- Standard operation resolves `ALIAS=PATH` from Engine-managed `agent_environment`; agent-local runtime profile file / source alias override is fallback compatibility only.
- Implementation requires `edit_scope` slots as `read_write`.
- Review uses `edit_scope ∪ verification_scope`; edit slots are `read_write`, verification-only slots are `read_only`.
- Verification requires `verification_scope` slots as `read_only`.
- Freshness defaults to `reuse_if_clean_and_ref_matches`.
- Cleanup defaults to `retain_until_a3_cleanup`; `cleanup_after_job` is available for validation/dev.

The runtime package surface exposes two separate command shapes:

- A3-side worker gateway options: `--worker-gateway agent-http --agent-shared-workspace-mode agent-materialized --agent-source-alias SLOT=ALIAS --agent-workspace-root PATH --agent-source-path ALIAS=PATH ...`
- Agent-side worker command: `a3-agent --engine <control-plane-url> --agent-token-file <path> --loop ...`

The first part, `slot -> alias`, is A3 job construction data. The second part, `alias -> local path`, is host/dev-env environment data but is still configured in Engine-side project config and transmitted per job as `agent_environment`. A3 doctor validates schema, alias coverage, and policy values; Engine-issued agent doctor jobs validate local filesystem accessibility from the agent runtime.

For direct preflight without an agent-local profile file, `a3-agent doctor` accepts the same agent-visible environment shape:

```text
a3-agent doctor \
  --control-plane-url http://a3-runtime:7393 \
  --workspace-root /path/from/agent/workspaces \
  --source-path member-portal-starters=/path/from/agent/member-portal-starters \
  --required-bin git
```

`-config <agent-runtime-profile.json>` remains as a compatibility input, but the release-facing path should prefer Engine-managed config rendered into doctor flags and job payload.

Focused release-package validation:

```text
agent-go/scripts/validation-release-package-doctor.sh
agent-go/scripts/validation-runtime-image-agent-export.sh
```

The first command builds the host-target release archive, verifies it through `a3 agent package verify`, exports it through `a3 agent package export`, and runs the exported `a3-agent doctor` against a temporary local git source without using an agent-local profile file.

The second command rebuilds/recreates the Docker A3 runtime image, verifies the image-bundled `/opt/a3/agents` package, exports `a3-agent` from inside the runtime container, copies it to the host, and runs the same profile-free doctor validation. This is the release-facing check that the Docker-distributed Engine can supply a usable host/dev-env agent binary.

### Non-Goals For This Slice

- Do not run Maven/Portal verification.
- Do not support remote Git auth.
- Do not support clone/fetch from arbitrary network remotes.
- Do not support production cleanup/quarantine execution yet; only add enough materializer cleanup API for tests and validation to remove created worktrees.
- Do not remove same-path gateway until agent materialization is proven through validation.

### Open Review Questions

- How should runtime profile config be distributed to host-installed agents?
- Should `command_working_dir` be added later, or is workspace root sufficient for all worker protocol commands?
- Is the initial 1 MiB worker protocol payload limit sufficient, or should the control-plane add separate body limits per endpoint?

## Review Questions

- Is synchronous polling acceptable for the first slice, or should phase completion become async before worker gateway integration?
- Is shared workspace path equivalence acceptable for compose/dev-env MVP, with agent-owned materialization handling local host/container differences?
- Is extracting `WorkerProtocol` the right boundary, or should `LocalWorkerGateway` expose a smaller internal result parser instead?
