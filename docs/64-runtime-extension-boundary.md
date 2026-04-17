# Runtime Extension Boundary

対象読者: A2O 設計者 / project package author / reviewer
文書種別: extension boundary

A2O Engine core must stay project-neutral. Project-specific behavior enters through project packages, command profiles, hook scripts, scenario tasks, and agent-side toolchains.

## Core May Know

- task lifecycle phases
- kanban provider interface
- repo slot model
- workspace materialization
- worker gateway protocol
- verification result semantics
- merge publication semantics
- evidence storage

## Project Package Owns

- board name and bootstrap lanes/tags
- trigger labels
- repo slot aliases and source paths
- build/test/format commands
- environment prerequisites for `a2o-agent`
- scenario tasks for validation
- project-specific bootstrap, remediation, or verification hooks

## Injection Rules

1. If a value names a product, repository, domain concept, build tool, or verification command, keep it in the project package.
2. If a behavior is required by every A2O project, express it as Engine domain logic and cover it with core tests.
3. If only one project needs a behavior, prefer a package hook or command profile.
4. If two or more reference products need the same behavior, consider promoting it to a documented preset.
5. Do not add fallback defaults that silently recreate a project package when config is missing.

## Current Package Layout

Reference packages use this shape:

```text
project-package/
  README.md
  project.yaml
  kanban/bootstrap.json
  commands/
  skills/
  scenarios/
```

`project.yaml` is the only author-facing package config. It owns package metadata, kanban bootstrap and selection, repo slots, agent prerequisites, runtime presets, project surface commands, and merge defaults. `commands/` contains project-owned scripts when declarative commands are not enough. `scenarios/` contains kanban task templates used for validation.

## Review Checklist

- The package can be bootstrapped with `a2o project bootstrap --package DIR`.
- Repo aliases are stable and do not encode local machine paths.
- Required binaries are listed under `agent.required_bins`.
- Build and verification commands can run from an agent-materialized workspace.
- Scenario tasks are small enough for deterministic validation.
- Any external A2O behavior change required by the package is tracked as a separate ticket before implementation.
