# Runtime Extension Boundary

This document defines what a project package may extend and what remains Engine-owned.

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
