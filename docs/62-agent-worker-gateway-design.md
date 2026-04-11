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
  - lets a remote `a3-agent` claim and execute a command
  - uploads logs/artifacts to A3-managed artifact storage
  - records `AgentJobResult`

`AgentWorkerGateway` is the bridge between these contracts. It must not replace worker result semantics with generic command success.

## Non-goals

- Do not make A3 image contain project-specific build/runtime toolchains.
- Do not make the agent understand A3 worker phase semantics directly.
- Do not store host/container local artifact paths in `AgentJobResult`.
- Do not make `run-verification` use the worker gateway in this slice. Verification currently uses command execution strategy and should be moved to agent jobs separately.
- Do not introduce async phase completion yet. The first slice keeps the existing synchronous `worker_gateway.run` interface.

## Current Implementation Facts

- `A3::Application::WorkerPhaseExecutionStrategy` calls `worker_gateway.run(...)` and expects an `A3::Application::ExecutionResult`.
- `A3::Infra::LocalWorkerGateway` owns the worker request/result file protocol and implementation `changed_files` canonicalization.
- `A3::Domain::AgentJobRequest` already carries `working_dir`, `command`, `args`, `env`, `timeout_seconds`, and `artifact_rules`.
- `A3::Infra::AgentHttpPullHandler` currently supports enqueue, claim next, artifact upload, and result submit.
- `A3::Infra::JsonAgentJobStore` already supports `fetch(job_id)`, but the HTTP handler does not expose `GET /v1/agent/jobs/{job_id}` yet.
- The compose smoke already proves that an `a3-runtime` control-plane container can send a command job to an `a3-agent` container and receive uploaded result artifacts.

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

The first slice only supports an explicit `same-path` shared workspace profile. The A3 process cannot prove that a remote/container agent sees the same path unless the runtime profile declares that contract. Therefore `agent-http` must require an explicit opt-in such as `--agent-shared-workspace-mode same-path`; without it the gateway fails before enqueueing. Later slices may add mount mapping or agent-side workspace materialization.

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
--agent-shared-workspace-mode same-path
--agent-job-timeout-seconds N
--agent-job-poll-interval-seconds N
```

Rules:

- default remains `local`
- `agent-http` requires `--agent-control-plane-url`
- `agent-http` requires `--agent-shared-workspace-mode same-path` for the first slice
- `agent-http` talks to an already running `a3 agent-server`; it does not start the control-plane server itself
- `agent-http` still requires a worker command unless using the skill name as command is explicitly intended
- `agent-http` treats `--worker-command` as an executable and `--worker-command-arg` as argv entries; shell expressions must be passed explicitly as `--worker-command sh --worker-command-arg -lc --worker-command-arg '...'`
- invalid combinations fail during CLI option validation

### First Smoke

Status: implemented in `spec/a3/infra/agent_worker_gateway_spec.rb`.

Add a focused smoke that proves the full bridge:

1. Start `a3 agent-server` with JSON job store and artifact store.
2. Prepare a temporary workspace containing a minimal worker script.
3. Run `AgentWorkerGateway#run` in one thread/process.
4. Run one `a3-agent` job against the server.
5. Assert the returned `ExecutionResult` came from `.a3/worker-result.json`.
6. Assert uploaded combined log artifact exists.

This is intentionally smaller than Portal full verification. Portal full verification should be a later slice after the gateway contract is stable.

## Failure Policy

- Missing or unsupported shared workspace mode: fail before enqueue with `observed_state=agent_workspace_unavailable`.
- Enqueue failure: fail with `failing_command=agent_job_enqueue`.
- Poll timeout: fail with `failing_command=agent_job_wait` and include job id/state diagnostics.
- Completed failed agent job without worker result: fail from `AgentJobResult` exit status and uploaded log references.
- Completed successful agent job without worker result: fail as `invalid_worker_result`; command success alone must not complete an A3 worker phase.

## Security Boundary

The first HTTP pull transport is dev/local only. It exposes job request details, including environment values, through the local control-plane API and does not include authentication. Auth, authorization, TLS, and response redaction are separate hardening slices before non-local deployment.

## Review Questions

- Is synchronous polling acceptable for the first slice, or should phase completion become async before worker gateway integration?
- Is shared workspace path equivalence acceptable for compose/dev-env MVP, with remote workspace materialization deferred?
- Is extracting `WorkerProtocol` the right boundary, or should `LocalWorkerGateway` expose a smaller internal result parser instead?
