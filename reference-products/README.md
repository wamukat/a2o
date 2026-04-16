# A2O Reference Products

This directory contains product fixtures for validating A2O without using a customer or internal product as the test bed.

The suite intentionally covers different runtime shapes:

- `typescript-api-web`: TypeScript API plus Web UI in one repository.
- `go-api-cli`: Go HTTP API plus CLI in one repository.
- `python-service`: Python service using the host or dev-env agent environment.
- `multi-repo-fixture`: Two repository fixture for parent-child and cross-repo validation.

Each product keeps its A2O package under `project-package/`. The package is designed to be bootstrapped with:

```sh
a2o project bootstrap --package ./reference-products/<product>/project-package
```

Do not use these fixtures to validate A2O runtime behavior until the product code, package manifests, and scenario tasks have been reviewed. The first runtime-flow test should be a separate, explicit step.

## Scope

These fixtures must not depend on Portal. They should stay small enough for an agent to understand quickly, while still including real source code, tests, build or compile commands, and realistic task scenarios.

External A2O behavior changes found while improving these fixtures require owner discussion before implementation.
