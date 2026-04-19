# Go API and CLI A2O Package

Use this package from the product root:

```sh
a2o project bootstrap --package ./project-package
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
```

The package targets the single Go repository in `..`.

Validation commands:

- `commands/bootstrap.sh`: lightweight package readiness check.
- `commands/verify.sh`: `go test ./...`.
- `commands/build.sh`: `go build ./...`.
- `commands/format.sh`: `gofmt`.

Runtime-flow validation is intentionally left for a later explicit test.
