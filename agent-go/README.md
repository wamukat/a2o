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

## Run Once

```sh
/tmp/a3-agent \
  -agent host-local \
  -control-plane-url http://127.0.0.1:7393
```

The current command runs a single poll cycle:

- `GET /v1/agent/jobs/next?agent=...`
- execute the requested command in the requested working directory
- `PUT /v1/agent/artifacts/{artifact_id}` for combined logs and matched artifact rules
- `POST /v1/agent/jobs/{job_id}/result`

Long-running service mode, installer packaging, auth, and policy hardening are intentionally left for later slices.
