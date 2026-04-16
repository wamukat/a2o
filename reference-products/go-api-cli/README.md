# Go API and CLI Reference Product

This product models a compact inventory workflow with a Go HTTP API and CLI.

It includes:

- `cmd/refapi`: HTTP API entrypoint.
- `cmd/refctl`: CLI entrypoint.
- `internal/inventory`: shared domain logic.
- Unit tests and standard Go build commands.
- An A2O project package in `project-package`.

## Commands

```sh
go test ./...
go build ./...
go run ./cmd/refctl summary
go run ./cmd/refapi
```

## A2O Package

```sh
a2o project bootstrap --package ./project-package
```
