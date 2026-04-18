# TypeScript API and Web A2O Package

Use this package from the product root:

```sh
a2o project bootstrap --package ./project-package
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
```

The package targets the single repository in `..`.

Validation commands:

- `commands/verify.sh`: typecheck and unit tests.
- `commands/build.sh`: production build.
- `commands/format.sh`: placeholder remediation hook until a formatter policy is chosen.

Runtime-flow validation is intentionally left for a later explicit test.
