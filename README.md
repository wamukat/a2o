# A2O Engine

[Japanese README](README.ja.md)

A2O is an automation engine that starts from kanban tasks and manages workspaces, agent execution, verification, merge, and evidence recording.

This repository contains the A2O Engine, Go host launcher, Go agent, Docker runtime image, reference product packages, and design documentation. The normal public entrypoints are `a2o`, `a2o-agent`, project packages, and the bundled kanban service.

## Principles

- A2O is a local-first runtime built around the bundled kanban service and `a2o-agent`.
- The Engine owns orchestration, state, the kanban adapter, the agent control plane, and evidence.
- Product-specific toolchains are not baked into the runtime image. They run through `a2o-agent` on the host or in a project dev environment.
- Product-specific knowledge belongs in the project package, not in Engine core.
- Core validation uses the small reference products under `reference-products/`.

## Reading Order

1. [docs/en/90-user-quickstart.md](docs/en/90-user-quickstart.md)
2. [docs/en/60-container-distribution-and-project-runtime.md](docs/en/60-container-distribution-and-project-runtime.md)
3. [docs/en/68-reference-product-suite.md](docs/en/68-reference-product-suite.md)
4. [docs/en/00-design-map.md](docs/en/00-design-map.md)
5. [docs/en/70-implementation-status.md](docs/en/70-implementation-status.md)

## Main Entrypoints

```sh
a2o host install
a2o project bootstrap --package ./reference-products/typescript-api-web/project-package
a2o kanban up
a2o kanban doctor
a2o kanban url
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
a2o runtime run-once
a2o runtime start
a2o runtime status
a2o runtime stop
```

The runtime image still contains `bin/a3` as the internal Engine CLI. That is an implementation compatibility name. The public user-facing entrypoints are `a2o` and `a2o-agent`.

The public launcher covers setup, kanban lifecycle, agent installation, foreground runtime execution, and resident scheduler lifecycle.

## Repository Layout

- Engine core: `lib/a3/`, `bin/a3`, `spec/`
- Host launcher / agent: `agent-go/`
- Docker runtime assets: `docker/`
- Kanban tooling: `tools/kanban/`
- Reference product packages: `reference-products/`
- English docs: [docs/en/](docs/en/)
- Japanese docs: [docs/ja/](docs/ja/)

## Validation

The reference product suite covers four product shapes:

- `reference-products/typescript-api-web/`
- `reference-products/go-api-cli/`
- `reference-products/python-service/`
- `reference-products/multi-repo-fixture/`

Each product has a `project-package/` directory and can create a runtime instance with `a2o project bootstrap --package <package>`. See [docs/en/68-reference-product-suite.md](docs/en/68-reference-product-suite.md) for the suite purpose, package contract, and validation boundary.
