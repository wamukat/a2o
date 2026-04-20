# Multi-Repo Fixture A2O Package

Use this package from the fixture root:

```sh
a2o project bootstrap --package ./project-package
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
```

The package targets two repositories:

- `repo_alpha`: `repos/catalog-service`
- `repo_beta`: `repos/storefront`

Parent tasks that span both repositories should use both concrete repo labels, `repo:catalog` and `repo:storefront`. Do not create a synthetic aggregate label that means "both repos".

Validation commands:

- `commands/bootstrap.sh`: lightweight fixture readiness check.
- `commands/verify-repo-alpha.sh`: catalog-service tests.
- `commands/verify-repo-beta.sh`: storefront tests.
- `commands/verify-all.sh`: both repository tests.
- `commands/build.sh`: both repository build checks.

Runtime-flow validation is intentionally left for a later explicit test.
