# A3 Agent Go Scaffold

This module contains the cross-platform `a3-agent` scaffold.

It intentionally depends only on the Go standard library. The Ruby reference agent remains useful for protocol fixtures, but this module is the target for host / dev-env installation.

## Build

```sh
go build -o /tmp/a3-agent ./cmd/a3-agent
```

For release-style cross-builds:

```sh
./scripts/build-release.sh
```

This writes binaries under `dist/` for:

- `darwin/amd64`
- `darwin/arm64`
- `linux/amd64`
- `linux/arm64`
- `windows/amd64`

## Local Install

```sh
./scripts/install-local.sh
```

By default this installs to `$HOME/.local/bin/a3-agent`. Override with `PREFIX=/path` or `BIN_DIR=/path`.

## Protocol Smoke

To verify the Go agent against the Ruby A3 control plane:

```sh
./scripts/smoke-ruby-control-plane.sh
```

This starts `a3 agent-server`, enqueues one verification job, runs the Go agent once, and checks that combined logs and matched artifacts were uploaded to the A3-managed artifact store.

To verify agent-owned workspace materialization and worker protocol transport:

```sh
./scripts/smoke-materialized-worker-protocol.sh
```

This starts the same Ruby control plane, creates a tiny clean Git source repo, enqueues one implementation job with `workspace_request` and `worker_protocol_request`, runs the Go agent with `--workspace-root` and `--source-alias`, and checks that the worker result is returned both as inline result JSON and as an uploaded `worker-result` artifact.

To verify the A3-side `AgentWorkerGateway` materialized path end to end:

```sh
./scripts/smoke-materialized-agent-gateway.sh
```

This starts the Ruby control plane, runs the Ruby `AgentWorkerGateway` in `agent-materialized` mode, runs the Go agent against a local Git source alias, and checks that the gateway completes from the returned worker protocol result while canonicalizing implementation `changed_files` from the agent workspace descriptor.

## Run Once

Create a runtime profile for the host or dev-env where commands will run:

```json
{
  "agent": "host-local",
  "control_plane_url": "http://127.0.0.1:7393",
  "workspace_root": "/tmp/a3-agent-workspaces",
  "source_aliases": {
    "member-portal-starters": "/path/to/scratch-parent-repo"
  }
}
```

Validate the profile:

```sh
/tmp/a3-agent doctor -config /path/to/agent-profile.json
```

Run one poll cycle with the profile:

```sh
/tmp/a3-agent -config /path/to/agent-profile.json
```

The individual flags remain available as overrides:

```sh
/tmp/a3-agent \
  -agent host-local \
  -control-plane-url http://127.0.0.1:7393 \
  -workspace-root /tmp/a3-agent-workspaces \
  -source-alias member-portal-starters=/path/to/scratch-parent-repo
```

The current command runs a single poll cycle:

- `GET /v1/agent/jobs/next?agent=...`
- execute the requested command in the requested working directory
- `PUT /v1/agent/artifacts/{artifact_id}` for combined logs and matched artifact rules
- `POST /v1/agent/jobs/{job_id}/result`

The runtime profile file is the host/dev-env side `alias -> local path` contract. A3 job payloads still carry only `slot -> alias`; they do not carry these local paths.

## Long-Running Mode

For daemon managers or container services, run the same profile in loop mode:

```sh
a3-agent -config /path/to/agent-profile.json --loop --poll-interval 2s
```

Useful flags and environment overrides:

- `--loop`: keep polling until the process is interrupted or fails.
- `--poll-interval` / `A3_AGENT_POLL_INTERVAL`: idle sleep duration, for example `2s`.
- `--max-iterations` / `A3_AGENT_MAX_ITERATIONS`: bounded loop count for smoke tests; `0` means unlimited.

Loop mode exits non-zero on control-plane or job execution errors so an external daemon manager can restart or alert. Installer packaging, auth, and deeper policy hardening are intentionally left for later slices.

Generate a service-manager template for local installation:

```sh
a3-agent service-template systemd \
  -config /etc/a3/agent-profile.json \
  -binary /usr/local/bin/a3-agent \
  > ~/.config/systemd/user/a3-agent.service

a3-agent service-template launchd \
  -config "$HOME/.a3/agent-profile.json" \
  -binary "$HOME/.local/bin/a3-agent" \
  > "$HOME/Library/LaunchAgents/dev.a3.agent.plist"
```

The template command only renders the unit/plist. Installing, loading, and enabling the service remains an operator or installer responsibility.
