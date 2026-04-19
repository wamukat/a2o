# Python Service A2O Package

Use this package from the product root:

```sh
a2o project bootstrap --package ./project-package
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
```

The package targets the single Python repository in `..`.

Validation commands:

- `commands/bootstrap.sh`: lightweight package readiness check.
- `commands/verify.sh`: unittest discovery and compile check.
- `commands/build.sh`: compile check.
- `commands/format.sh`: placeholder remediation hook until a formatter policy is chosen.

Runtime-flow validation is intentionally left for a later explicit test.
