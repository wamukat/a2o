# Multi-Repo Reference Fixture

This fixture provides two small repositories for A2O parent-child validation.

- `repos/catalog-service`: publishes catalog data and validates a JSON contract.
- `repos/storefront`: consumes the catalog contract and renders a storefront summary.

The A2O package under `project-package/` includes repo-scope labels and task templates for:

- A single-repo task against `repo_alpha`.
- A single-repo task against `repo_beta`.
- A parent task that creates child work for both repositories.

This fixture does not run an A2O runtime flow by itself. The next step is to bootstrap it and create explicit validation tickets on an isolated board.
