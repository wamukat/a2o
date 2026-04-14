# A3 Agent Go Scaffold

This module contains the `a3-agent` scaffold for macOS, Linux, and WSL2 Ubuntu.

It intentionally depends only on the Go standard library. The Ruby reference agent class remains useful for protocol fixtures, but it is not a release executable. This module is the only `a3-agent` target for host / dev-env installation.

## Build

```sh
go build -o /tmp/a3-agent ./cmd/a3-agent
go build -o /tmp/a3 ./cmd/a3
```

For release-style builds:

```sh
VERSION=0.1.0 ./scripts/build-release.sh
```

This writes binaries and release archives under `dist/` for:

- `darwin/amd64`
- `darwin/arm64`
- `linux/amd64`
- `linux/arm64`

Release output includes:

- platform binary directories, for example `dist/linux-amd64/a3-agent` and `dist/linux-amd64/a3`
- archives, for example `dist/a3-agent-0.1.0-linux-amd64.tar.gz`
- `dist/checksums.txt`
- `dist/release-manifest.jsonl`

Use `TARGETS="linux/amd64 darwin/arm64"` to build a subset. Set `PACKAGE_ARCHIVES=0` to build binaries only.
Windows native execution is not a standard target. Windows users run the Linux archive from WSL2 Ubuntu.

## Local Install

Install from source when Go is available:

```sh
./scripts/install-local.sh
```

By default this installs to `$HOME/.local/bin/a3-agent` and `$HOME/.local/bin/a3`. Override with `PREFIX=/path` or `BIN_DIR=/path`.

Install from a release archive when Go is not required on the target host:

```sh
./scripts/install-release.sh dist/a3-agent-0.1.0-linux-amd64.tar.gz
```

Verify the release checksum before installing:

```sh
CHECKSUM_FILE=dist/checksums.txt \
./scripts/install-release.sh dist/a3-agent-0.1.0-linux-amd64.tar.gz
```

The installer only installs the binary. It does not install or enable OS service definitions. Standard A3 operation starts the agent manually in loop mode from an operator terminal or from the project dev-env container.

## Host Launcher

`a3` is the host-side launcher. It is the user-facing command for Docker A3 Engine operations and host/dev-env agent installation. It is a Go binary and does not require Ruby on the host.

Install the host launcher from a published A3 Engine image:

```sh
mkdir -p "$HOME/.local/bin" "$HOME/.local/share"
docker run --rm \
  -v "$HOME/.local:/install" \
  docker.io/<org>/a3-engine:latest \
  a3 host install \
    --output-dir /install/bin \
    --share-dir /install/share/a3 \
    --runtime-image docker.io/<org>/a3-engine:latest
```

The container command copies platform binaries such as `a3-darwin-amd64` and `a3-linux-amd64`, copies A3 distribution assets such as the standard compose file under `$HOME/.local/share/a3`, records the runtime image used by later `a3 runtime ...` commands, then writes a host-side `a3` shell wrapper that selects the right binary with `uname`. Mount the install prefix, not only the `bin` directory, so the share assets are exported to the host. The host does not need Ruby.

Detect the package target for the current host:

```sh
a3 agent target
```

Export `a3-agent` from the A3 Engine runtime image:

```sh
a3 agent install \
  --target auto \
  --output ./.work/a3-agent/bin/a3-agent \
  --build
```

This command starts the runtime service if needed, verifies the matching agent package inside the runtime container, exports it to the requested host path, and marks it executable. Use `--build` when validating local source changes against a freshly built runtime image. Omit `--build` when using a prebuilt release image.

The standard compose file is an A3 distribution asset. Project packages provide bootstrap/config values; they do not provide the A3/SoloBoard compose file. `--compose-file`, `--compose-project`, and `--runtime-service` remain available as development/diagnostic overrides, but they are not part of the normal user path.

After `a3 project bootstrap --package ./a3-project`, runtime commands discover `.a3/runtime-instance.json` from the current directory upward:

```sh
a3 runtime up
a3 runtime doctor
a3 runtime run-once
```

`a3 runtime run-once` currently delegates to the project package `runtime/run_once.sh` while keeping that script out of the user-facing command path. Branch refs created by runtime jobs are namespaced by the compose project, for example `refs/heads/a3/a3-portal/work/Portal-1`, so isolated boards do not reuse historical live-repo branches with the same task number. The generic Go implementation will absorb that script in later slices.

## Deployment Shapes

`a3-agent` is the project-runtime side of the A3 distribution. A3 is a local-first runtime: A3, SoloBoard, and the agent run on the same host or inside the same local Docker compose/dev-env network. The current data model is not a central A3 server with remote multi-agent workers.

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

Out of scope for the current runtime:

- central A3 server operation
- remote worker pools across multiple machines
- multi-tenant agent registry / capability scheduling
- remote artifact routing outside the local A3-managed artifact store

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
  --engine http://127.0.0.1:7393 \
  -agent-token-file /run/secrets/a3-agent-token \
  -workspace-root /tmp/a3-agent-workspaces \
  -source-alias member-portal-starters=/path/to/scratch-parent-repo
```

`--engine` is the user-facing alias for `--control-plane-url`. Both flags are accepted for normal execution and `doctor`.

The current command runs a single poll cycle:

- `GET /v1/agent/jobs/next?agent=...`
- execute the requested command in the requested working directory
- `PUT /v1/agent/artifacts/{artifact_id}` for combined logs and matched artifact rules
- `POST /v1/agent/jobs/{job_id}/result`

The runtime profile file is the host/dev-env side `alias -> local path` contract. A3 job payloads still carry only `slot -> alias`; they do not carry these local paths.

`agent_token` is optional for local-only development. When the A3 control plane is started with `--agent-token` / `--agent-token-file` or `A3_AGENT_TOKEN` / `A3_AGENT_TOKEN_FILE`, the Go agent must provide the same agent token through `A3_AGENT_TOKEN`, `-agent-token`, `agent_token_file`, `A3_AGENT_TOKEN_FILE`, `-agent-token-file`, or the inline profile `agent_token`. A3-side enqueue/fetch clients may use a separate control token (`--agent-control-token-file` or `A3_AGENT_CONTROL_TOKEN_FILE`) while the Go agent continues to use only the agent token. Prefer token files for service manager / container operation so tokens are not exposed through process arguments.

The runtime profile rejects remote `http://` control-plane URLs by default. Loopback URLs (`127.0.0.1` / `localhost`) and single-label Docker service names such as `http://a3-runtime:7393` are treated as local topology. Remote deployment is out of scope for the current runtime; `allow_insecure_remote` is only a diagnostic escape hatch and should not appear in the standard runbook.

## Manual Loop Mode

Run the same profile in loop mode from a terminal while A3 is operating:

```sh
a3-agent --engine http://127.0.0.1:7393 --loop --poll-interval 2s
```

Useful flags and environment overrides:

- `--loop`: keep polling until the process is interrupted or fails.
- `--poll-interval` / `A3_AGENT_POLL_INTERVAL`: idle sleep duration, for example `2s`.
- `--max-iterations` / `A3_AGENT_MAX_ITERATIONS`: bounded loop count for manual verification; `0` means unlimited.

Loop mode exits non-zero on control-plane or job execution errors. If an operator wants OS-managed restart later, they can wrap this command outside A3. The current A3 distribution intentionally does not own systemd, launchd, or Windows service registration. Windows users run A3 through WSL2 Ubuntu and use the same manual loop path.
