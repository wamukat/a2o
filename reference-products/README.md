# A2O Reference Products

This directory contains product fixtures for validating A2O with small, owned sample projects.

The suite intentionally covers different runtime shapes:

- `typescript-api-web`: TypeScript API plus Web UI in one repository.
- `go-api-cli`: Go HTTP API plus CLI in one repository.
- `python-service`: Python service using the host or dev-env agent environment.
- `multi-repo-fixture`: Two-repository fixture for parent-child and cross-repo validation.

Each product keeps its A2O package under `project-package/`. Bootstrap a package with:

```sh
a2o project bootstrap --package ./reference-products/<product>/project-package
```

Run runtime-flow validation only as an explicit test step after the product code, package manifest, and task templates have been reviewed.

## Scope

These fixtures should stay small enough for an agent to understand quickly, while still including real source code, tests, build or compile commands, and realistic task templates.

External A2O behavior changes found while improving these fixtures require owner discussion before implementation.
