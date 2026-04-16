# Multi-Repo Implementation Skill

Work in the fixture repository next to this package.

Repo scopes:

- `repo_alpha`: catalog-service repository under `repos/catalog-service`.
- `repo_beta`: storefront repository under `repos/storefront`.
- `both`: parent or integration work spanning both repositories.

Rules:

- Keep catalog data ownership in `repo_alpha`.
- Keep presentation logic in `repo_beta`.
- For child tasks, modify only the requested repo scope unless the ticket explicitly asks for cross-repo work.
- Add or update tests in the changed repository.
- Run the repo-specific verification command for child work and `commands/verify-all.sh` for parent work.
- If a task requires changing A2O public behavior, stop and ask the project owner before proceeding.
