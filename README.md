# A2O Engine

[Japanese README](README.ja.md)

A2O stands for Agentic AI Orchestrator. A2O is an automation engine that starts from kanban tasks and manages workspaces, agent execution, verification, merge, and evidence recording.

This repository contains the A2O Engine, Go host launcher, Go agent, Docker runtime image, reference product packages, and design documentation. The normal public entrypoints are `a2o`, `a2o-agent`, project packages, and the bundled kanban service.

## Principles

- A2O is a local-first runtime built around the bundled kanban service and `a2o-agent`.
- The Engine owns orchestration, state, the kanban adapter, the agent control plane, and evidence.
- Product-specific toolchains are not baked into the runtime image. They run through `a2o-agent` on the host or in a project dev environment.
- Product-specific knowledge belongs in the project package, not in Engine core.
- Core validation uses the small reference products under `reference-products/`.

## Reading Order

User documentation:

1. [docs/en/user/00-user-quickstart.md](docs/en/user/00-user-quickstart.md)
2. [docs/en/user/10-project-package-schema.md](docs/en/user/10-project-package-schema.md)
3. [docs/en/user/20-runtime-distribution.md](docs/en/user/20-runtime-distribution.md)
4. [docs/en/user/30-runtime-naming-boundary.md](docs/en/user/30-runtime-naming-boundary.md)
5. [docs/en/user/40-release-status.md](docs/en/user/40-release-status.md)
6. [docs/en/user/50-project-package-authoring-guide.md](docs/en/user/50-project-package-authoring-guide.md)

Developer documentation:

1. [docs/en/dev/00-design-map.md](docs/en/dev/00-design-map.md)
2. [docs/en/dev/10-engineering-rulebook.md](docs/en/dev/10-engineering-rulebook.md)
3. [docs/en/dev/20-bounded-context-and-language.md](docs/en/dev/20-bounded-context-and-language.md)
4. [docs/en/dev/30-core-domain-model.md](docs/en/dev/30-core-domain-model.md)
5. [docs/en/dev/40-workspace-and-repo-slot-model.md](docs/en/dev/40-workspace-and-repo-slot-model.md)
6. [docs/en/dev/50-project-surface.md](docs/en/dev/50-project-surface.md)
7. [docs/en/dev/60-evidence-and-rerun-diagnosis.md](docs/en/dev/60-evidence-and-rerun-diagnosis.md)
8. [docs/en/dev/70-agent-worker-gateway-design.md](docs/en/dev/70-agent-worker-gateway-design.md)
9. [docs/en/dev/80-runtime-extension-boundary.md](docs/en/dev/80-runtime-extension-boundary.md)
10. [docs/en/dev/90-reference-product-suite.md](docs/en/dev/90-reference-product-suite.md)
11. [docs/en/dev/95-kanban-adapter-boundary.md](docs/en/dev/95-kanban-adapter-boundary.md)

## Main Entrypoints

```sh
a2o host install
a2o project bootstrap --package ./reference-products/typescript-api-web/project-package
a2o project lint --package ./reference-products/typescript-api-web/project-package
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
- English user docs: [docs/en/user/](docs/en/user/)
- English developer docs: [docs/en/dev/](docs/en/dev/)
- Japanese docs: [docs/ja/](docs/ja/)

## Validation

The reference product suite covers four product shapes:

- `reference-products/typescript-api-web/`
- `reference-products/go-api-cli/`
- `reference-products/python-service/`
- `reference-products/multi-repo-fixture/`

Each product has a `project-package/` directory and can create a runtime instance with `a2o project bootstrap --package <package>`. See [docs/en/dev/90-reference-product-suite.md](docs/en/dev/90-reference-product-suite.md) for the suite purpose, package contract, and validation boundary.
