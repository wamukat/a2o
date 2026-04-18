# A2O Agent Go Scaffold

This module contains the public `a2o-agent` scaffold for macOS, Linux, and WSL2 Ubuntu. The internal implementation name remains `a3-agent` for the current release.

It intentionally depends only on the Go standard library. The Ruby reference agent class remains useful for protocol fixtures, but it is not a release executable. This module is the only agent target for host / dev-env installation.

## Build

```sh
go build -o /tmp/a2o-agent ./cmd/a3-agent
go build -o /tmp/a2o ./cmd/a3
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

- platform binary directories, for example `dist/linux-amd64/a2o-agent`, `dist/linux-amd64/a2o`, and their `a3` compatibility aliases
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

By default this installs compatibility binaries under `$HOME/.local/bin`. Public runtime installs should prefer `a2o host install` and `a2o agent install`.

Install from a release archive when Go is not required on the target host:

```sh
./scripts/install-release.sh dist/a3-agent-0.1.0-linux-amd64.tar.gz
```

Verify the release checksum before installing:

```sh
CHECKSUM_FILE=dist/checksums.txt \
./scripts/install-release.sh dist/a3-agent-0.1.0-linux-amd64.tar.gz
```

The installer installs `a2o-agent` and compatibility alias `a3-agent`. It does not install or enable OS service definitions. Standard A2O operation uses `a2o host install`, `a2o project bootstrap`, `a2o kanban ...`, `a2o agent install`, and `a2o runtime ...`; direct agent loop commands are compatibility / diagnostic tools for operators and developers.

## Host Launcher

`a2o` is the host-side launcher. It is the user-facing command for Docker A2O Engine operations and host/dev-env agent installation. It is a Go binary and does not require Ruby on the host. `a3` remains as an internal / compatibility alias.

Install the host launcher from a published A2O Engine image:

```sh
mkdir -p "$HOME/.local/bin" "$HOME/.local/share"
docker run --rm \
  -v "$HOME/.local:/install" \
  ghcr.io/wamukat/a2o-engine:latest \
  a2o host install \
    --output-dir /install/bin \
    --share-dir /install/share/a2o \
    --runtime-image ghcr.io/wamukat/a2o-engine:latest
```

The container command copies platform binaries such as `a2o-darwin-amd64` and `a2o-linux-amd64`, copies A2O distribution assets such as the standard compose file under `$HOME/.local/share/a2o`, records the runtime image used by later `a2o kanban ...` commands, then writes a host-side `a2o` shell wrapper that selects the right binary with `uname`. Compatibility `a3` launchers are also installed. Mount the install prefix, not only the `bin` directory, so the share assets are exported to the host. The host does not need Ruby.

Detect the package target for the current host:

```sh
a2o agent target
```

Export `a2o-agent` from the A2O Engine runtime image:

```sh
a2o agent install \
  --target auto \
  --output ./.work/a2o/agent/bin/a2o-agent \
  --build
```

This command starts the runtime service if needed, verifies the matching agent package inside the runtime container, exports it to the requested host path, and marks it executable. Use `--build` when validating local source changes against a freshly built runtime image. Omit `--build` when using a prebuilt release image.

The standard compose file is an A2O distribution asset. Project packages provide bootstrap/config values; they do not provide the A2O runtime compose file. `--compose-file`, `--compose-project`, and `--runtime-service` remain available as development/diagnostic overrides, but they are not part of the normal user path.

Start a new package from the template generator so the executor contract is not hand-written:

```sh
a2o project template \
  --package-name my-product \
  --kanban-project MyProduct \
  --language node \
  --executor-bin your-ai-worker \
  --output ./a2o-project/project.yaml
```

The generated file uses the compact `runtime.executor.command` form. A2O expands it to the default stdin-bundle executor internally, so existing full executor objects remain compatible.
When `--output` points to a file, the generator also creates `kanban/bootstrap.json`. Existing files are not overwritten unless `--force` is passed.

After `a2o project bootstrap --package ./a2o-project`, runtime commands discover `.work/a2o/runtime-instance.json` from the current directory upward:

```sh
a2o kanban up
a2o kanban doctor
a2o kanban url
a2o runtime doctor
a2o runtime run-once
a2o runtime loop --interval 60s
a2o runtime start --interval 60s
a2o runtime status
a2o runtime stop
```

Execution-loop commands live under `a2o runtime ...`, not `a2o kanban ...`. Branch refs created by internal runtime jobs remain namespaced by the compose project, for example `refs/heads/a3/a2o-reference/work/A2OReference-1`, so isolated boards do not reuse existing live-repo branches with the same task number.

## Deployment Shapes

`a2o-agent` is the project-runtime side of the A2O distribution. A2O is a local-first runtime: A2O, SoloBoard, and the agent run on the same host or inside the same local Docker compose/dev-env network. The current data model is not a central A2O server with remote multi-agent workers.

Supported shapes:

- Host agent
  - Install the release archive on the host.
  - Point `workspace_root` and `source_aliases` at host paths.
  - Use loopback control-plane URL such as `http://127.0.0.1:7393`.
- Dev-env container agent
  - Copy or install the release archive into the project dev-env image.
  - Point `workspace_root` and `source_aliases` at paths inside that container.
  - Use the compose service name for the internal A2O control plane, for example `http://a3-runtime:7393`.
- CI runner agent
  - Install from release archive during the job setup step.
  - Use a job-local `workspace_root` and token files mounted from CI secrets.

In all shapes, Engine-managed job payloads and doctor inputs are the standard contract. Agent-local runtime profile files remain as fallback compatibility for diagnostics and older validation fixtures. Logs and artifacts are uploaded to the internal A2O-managed artifact store and must not be returned as host-local paths in `JobResult`.

Out of scope for the current runtime:

- central A2O server operation
- remote worker pools across multiple machines
- multi-tenant agent registry / capability scheduling
- remote artifact routing outside the local internal A2O-managed artifact store

## Compatibility Single Poll

This section is developer / diagnostic guidance, not the normal A2O user path. Standard users install the agent with `a2o agent install` and let the Engine-managed project package provide workspace root, source paths, required bins, and environment through job payloads and doctor jobs.

Create a runtime profile for the host or dev-env where commands will run:

```json
{
  "agent": "host-local",
  "control_plane_url": "http://127.0.0.1:7393",
  "agent_token_file": "/run/secrets/a2o-agent-token",
  "workspace_root": "/tmp/a2o-agent-workspaces",
  "source_aliases": {
    "repo_alpha": "/path/to/reference-products/multi-repo-fixture/repos/catalog-service",
    "repo_beta": "/path/to/reference-products/multi-repo-fixture/repos/storefront"
  }
}
```

Validate the profile:

```sh
/tmp/a2o-agent doctor -config /path/to/agent-profile.json
```

Run one poll cycle with the profile:

```sh
/tmp/a2o-agent -config /path/to/agent-profile.json
```

The individual flags remain available as overrides:

```sh
/tmp/a2o-agent \
  -agent host-local \
  --engine http://127.0.0.1:7393 \
  -agent-token-file /run/secrets/a2o-agent-token \
  -workspace-root /tmp/a2o-agent-workspaces \
  -source-alias repo_alpha=/path/to/reference-products/multi-repo-fixture/repos/catalog-service \
  -source-alias repo_beta=/path/to/reference-products/multi-repo-fixture/repos/storefront
```

`--engine` is the user-facing alias for `--control-plane-url`. Both flags are accepted for normal execution and `doctor`.

The current command runs a single poll cycle:

- `GET /v1/agent/jobs/next?agent=...`
- execute the requested command in the requested working directory
- `PUT /v1/agent/artifacts/{artifact_id}` for combined logs and matched artifact rules
- `POST /v1/agent/jobs/{job_id}/result`

The runtime profile file is a compatibility fallback for the host/dev-env side `alias -> local path` contract. The standard path should use Engine-managed agent environment config rendered into doctor flags and job payloads.

`agent_token` is optional for local-only development. When the internal A2O control plane is started with `--agent-token` / `--agent-token-file` or `A3_AGENT_TOKEN` / `A3_AGENT_TOKEN_FILE`, the Go agent must provide the same agent token through `A3_AGENT_TOKEN`, `-agent-token`, `agent_token_file`, `A3_AGENT_TOKEN_FILE`, `-agent-token-file`, or the inline profile `agent_token`. Engine-side enqueue/fetch clients may use a separate control token (`--agent-control-token-file` or `A3_AGENT_CONTROL_TOKEN_FILE`) while the Go agent continues to use only the agent token. Prefer token files for service manager / container operation so tokens are not exposed through process arguments.

The runtime profile rejects remote `http://` control-plane URLs by default. Loopback URLs (`127.0.0.1` / `localhost`) and single-label Docker service names such as `http://a3-runtime:7393` are treated as local topology. Remote deployment is out of scope for the current runtime; `allow_insecure_remote` is only a diagnostic escape hatch and should not appear in the standard runbook.

## Compatibility Manual Loop Mode

This mode is for local diagnostics, validation fixtures, or operator-controlled troubleshooting. It is not the primary A2O setup flow.

Run the same profile in loop mode from a terminal while A2O is operating:

```sh
a2o-agent --engine http://127.0.0.1:7393 --loop --poll-interval 2s
```

Useful flags and environment overrides:

- `--loop`: keep polling until the process is interrupted or fails.
- `--poll-interval` / `A3_AGENT_POLL_INTERVAL`: idle sleep duration, for example `2s`.
- `--max-iterations` / `A3_AGENT_MAX_ITERATIONS`: bounded loop count for manual verification; `0` means unlimited.

Loop mode exits non-zero on control-plane or job execution errors. If an operator wants OS-managed restart later, they can wrap this command outside A2O. The current A2O distribution intentionally does not own systemd, launchd, or Windows service registration. Windows users run A2O through WSL2 Ubuntu and should still start from the standard `a2o ...` lifecycle commands.
