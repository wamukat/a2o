# Multi-Repo Fixture A2O Package

Use this package from the fixture root:

```sh
a2o project bootstrap --package ./project-package
```

The package targets two repositories:

- `repo_alpha`: `repos/catalog-service`
- `repo_beta`: `repos/storefront`

Validation commands:

- `commands/verify-repo-alpha.sh`: catalog-service tests.
- `commands/verify-repo-beta.sh`: storefront tests.
- `commands/verify-all.sh`: both repository tests.
- `commands/build.sh`: both repository build checks.

Runtime-flow validation is intentionally left for a later explicit test.
