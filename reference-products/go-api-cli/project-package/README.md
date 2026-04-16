# Go API and CLI A2O Package

Use this package from the product root:

```sh
a2o project bootstrap --package ./project-package
```

The package targets the single Go repository in `..`.

Validation commands:

- `commands/verify.sh`: `go test ./...`.
- `commands/build.sh`: `go build ./...`.
- `commands/format.sh`: `gofmt`.

Runtime-flow validation is intentionally left for a later explicit test.
