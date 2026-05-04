# Runtime Extension Boundary

A2O Engine core stays product-agnostic. Product-specific behavior is injected through project packages, command profiles, hook scripts, task templates, and the agent-side toolchain.

Read this when deciding whether a new requirement belongs in A2O core or in a project package. Behavior needed across products is a core candidate; behavior needed by one product should stay in the package or command layer.

## Runtime Placement

This document defines how far the A2O core runtime goes and where it delegates to project packages, commands, and skills. Use it as a placement guide when adding runtime features or project-specific automation.

## What Core May Know

- task lifecycle phases
- kanban provider interface
- repo slot model
- workspace materialization
- worker gateway protocol
- verification result semantics
- merge publication semantics
- evidence persistence

## What Project Packages Own

- board name and project-owned initialization labels
- project-owned task labels
- repo slot aliases and source paths
- build, test, and formatting commands
- `a2o-agent` environment prerequisites
- verification task templates
- project-specific initialization, remediation, and verification hooks

## Injection Rules

1. Values that name a product, repository, domain concept, build tool, or verification command belong in the project package.
2. Behavior required by every A2O project belongs in Engine domain logic and should be covered by core tests.
3. Behavior required by only one project should prefer a package hook or command profile.
4. When two or more reference products need the same behavior, consider promoting it to a documented preset.
5. Do not add fallback defaults that silently regenerate project packages when configuration is missing.

## Current Package Layout

Reference packages use this shape:

```text
project-package/
  README.md
  project.yaml
  commands/
  skills/
  task-templates/
```

`project.yaml` is the only author-facing package configuration file. It owns package metadata, kanban initialization and selection criteria, repo slots, agent prerequisites, runtime-exposed commands, and merge defaults. A2O-managed lanes and internal coordination labels are provider or runtime defaults, not package responsibilities.

`commands/` holds project-managed scripts when declarative commands are not enough. `task-templates/` holds kanban task templates used for validation.

## Extension Principles

- Public extension points should be explicit in `project.yaml`.
- Internal runtime wiring should not leak into package authoring.
- A2O owns lifecycle, state, evidence, and scheduler semantics.
- Projects own product commands and product-specific skills.

## Project-Owned Extension Points

Project packages may provide:

- phase skills
- implementation/review executor command
- verification commands
- remediation commands
- repo slot mapping
- repo labels
- human project labels
- task templates
- merge policy and live target ref within supported Engine semantics

## Engine-Owned Runtime

A2O owns:

- kanban provider lifecycle
- internal trigger and coordination labels
- lane provisioning
- scheduler loop
- worker gateway protocol
- workspace materialization contract
- evidence persistence
- blocked diagnosis
- runtime image distribution

## Hooks

Project-specific hook scripts are acceptable when declarative commands are insufficient. They should live in the project package, have deterministic behavior, and be documented as package-owned.

Hooks must not require users to edit generated `.work/a2o` files.

## Configuration Boundary

Package authors should author only `project.yaml` and files under the project package. Generated runtime instance config, launcher config, agent workspaces, and runtime state are A2O output.

## Review Checklist

- The package can be initialized with `a2o project bootstrap`; use `--package DIR` when it is not under `./a2o-project` or `./project-package`.
- Repo aliases are stable and do not embed local machine paths.
- Product/toolchain required binaries are listed in `agent.required_bins`; A2O core must not add product-specific defaults.
- Build and verification commands can run from the agent-materialized workspace.
- Scenario tasks are small enough for deterministic validation.
- External A2O specification changes required by the package are tracked as separate tickets before implementation.
