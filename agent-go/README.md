# A3 Agent Go Scaffold

This module contains the cross-platform `a3-agent` scaffold.

It intentionally depends only on the Go standard library. The Ruby reference agent remains useful for protocol fixtures, but this module is the target for host / dev-env installation.

## Build

```sh
go build -o /tmp/a3-agent ./cmd/a3-agent
```

For release-style cross-builds:

```sh
VERSION=0.1.0 ./scripts/build-release.sh
```

This writes binaries and release archives under `dist/` for:

- `darwin/amd64`
- `darwin/arm64`
- `linux/amd64`
- `linux/arm64`
- `windows/amd64`

Release output includes:

- platform binary directories, for example `dist/linux-amd64/a3-agent`
- archives, for example `dist/a3-agent-0.1.0-linux-amd64.tar.gz`
- `dist/checksums.txt`
- `dist/release-manifest.jsonl`

Use `TARGETS="linux/amd64 darwin/arm64"` to build a subset. Set `PACKAGE_ARCHIVES=0` to build binaries only.

## Local Install

Install from source when Go is available:

```sh
./scripts/install-local.sh
```

By default this installs to `$HOME/.local/bin/a3-agent`. Override with `PREFIX=/path` or `BIN_DIR=/path`.

Install from a release archive when Go is not required on the target host:

```sh
./scripts/install-release.sh dist/a3-agent-0.1.0-linux-amd64.tar.gz
```

Verify the release checksum before installing:

```sh
CHECKSUM_FILE=dist/checksums.txt \
./scripts/install-release.sh dist/a3-agent-0.1.0-linux-amd64.tar.gz
```

To also install a user service template:

```sh
INSTALL_SERVICE=1 \
CONFIG_PATH="$HOME/.a3/agent-profile.json" \
./scripts/install-release.sh dist/a3-agent-0.1.0-linux-amd64.tar.gz
```

The installer detects `systemd` on Linux and `launchd` on macOS. Override with `SERVICE_MANAGER=systemd|launchd`, `SERVICE_DIR=/path`, `SERVICE_LABEL=name`, `POLL_INTERVAL=2s`, or `WORKING_DIR=/path`.

By default the service file is written but not loaded. Set `ENABLE_SERVICE=1` to run the platform load/enable command after writing the template.

## Deployment Shapes

`a3-agent` is the project-runtime side of the A3 distribution. A3 and SoloBoard can run in Docker while the agent runs either on the host or inside a project dev-env container.

Supported shapes:

- Host agent
  - Install the release archive on the host.
  - Point `workspace_root` and `source_aliases` at host paths.
  - Use loopback control-plane URL such as `http://127.0.0.1:7393`.
- Dev-env container agent
  - Copy or install the release archive into the project dev-env image.
  - Point `workspace_root` and `source_aliases` at paths inside that container.
  - Use the compose service name for the A3 control plane, for example `http://a3-runtime:7393`.
- CI runner agent
  - Install from release archive during the job setup step.
  - Use a job-local `workspace_root` and token files mounted from CI secrets.

In all shapes, the runtime profile is the local contract. A3 job payloads carry repo slots and source aliases; they do not carry host-specific source paths. Logs and artifacts are uploaded to the A3-managed artifact store and must not be returned as host-local paths in `JobResult`.

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
  "agent_token_file": "/run/secrets/a3-agent-token",
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
  -agent-token-file /run/secrets/a3-agent-token \
  -workspace-root /tmp/a3-agent-workspaces \
  -source-alias member-portal-starters=/path/to/scratch-parent-repo
```

The current command runs a single poll cycle:

- `GET /v1/agent/jobs/next?agent=...`
- execute the requested command in the requested working directory
- `PUT /v1/agent/artifacts/{artifact_id}` for combined logs and matched artifact rules
- `POST /v1/agent/jobs/{job_id}/result`

The runtime profile file is the host/dev-env side `alias -> local path` contract. A3 job payloads still carry only `slot -> alias`; they do not carry these local paths.

`agent_token` is optional for local-only development. When the A3 control plane is started with `--agent-token` / `--agent-token-file` or `A3_AGENT_TOKEN` / `A3_AGENT_TOKEN_FILE`, the Go agent must provide the same agent token through `A3_AGENT_TOKEN`, `-agent-token`, `agent_token_file`, `A3_AGENT_TOKEN_FILE`, `-agent-token-file`, or the inline profile `agent_token`. A3-side enqueue/fetch clients may use a separate control token (`--agent-control-token-file` or `A3_AGENT_CONTROL_TOKEN_FILE`) while the Go agent continues to use only the agent token. Prefer token files for service manager / container operation so tokens are not exposed through process arguments.

The runtime profile rejects remote `http://` control-plane URLs by default. Loopback URLs (`127.0.0.1` / `localhost`) and single-label Docker service names such as `http://a3-runtime:7393` are treated as local topology. Use `https://` for remote deployment, or set `allow_insecure_remote` only for an explicitly reviewed exception.

## Long-Running Mode

For daemon managers or container services, run the same profile in loop mode:

```sh
a3-agent -config /path/to/agent-profile.json --loop --poll-interval 2s
```

Useful flags and environment overrides:

- `--loop`: keep polling until the process is interrupted or fails.
- `--poll-interval` / `A3_AGENT_POLL_INTERVAL`: idle sleep duration, for example `2s`.
- `--max-iterations` / `A3_AGENT_MAX_ITERATIONS`: bounded loop count for smoke tests; `0` means unlimited.

Loop mode exits non-zero on control-plane or job execution errors so an external daemon manager can restart or alert. Release archive generation, local service template installation, and shared bearer-token auth are available; deeper policy hardening remains for later slices.

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
