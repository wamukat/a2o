# Python Service A2O Package

Use this package from the product root:

```sh
a2o project bootstrap --package ./project-package
```

The package targets the single Python repository in `..`.

Validation commands:

- `commands/verify.sh`: unittest discovery and compile check.
- `commands/build.sh`: compile check.
- `commands/format.sh`: placeholder remediation hook until a formatter policy is chosen.

Runtime-flow validation is intentionally left for a later explicit test.
