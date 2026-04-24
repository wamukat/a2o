# A2O Project Surface

This document defines the small project-owned configuration surface. The project package should express product-specific knowledge without turning `project.yaml` into an unrestricted Engine configuration file.

Read this when deciding what belongs in `project.yaml` and what must remain owned by A2O core. A broad configuration surface weakens the task lifecycle, evidence, and merge guarantees that A2O is responsible for preserving. The script boundary that project packages can rely on is defined in [55-project-script-contract.md](55-project-script-contract.md).

## Runtime Placement

This document sits at the boundary between a user-managed project package and Engine-owned runtime behavior. `project.yaml` is input for task selection, repo slots, phase commands, skills, verification and remediation, and merge policy. It is not the place to redefine scheduler behavior, workspace topology, the evidence model, or kanban provider implementation.

## 1. Goals

- Keep project-specific injection points minimal.
- Avoid carrying old product-specific complexity into Engine core.
- Make `project.yaml` a clear package config rather than a bag of runtime internals.
- Let A2O own task lifecycle, workspace topology, evidence, and merge semantics.

## 2. Minimal Surface

Project packages may configure:

- implementation skill
- review skill
- parent review skill
- implementation/review executor commands
- verification commands
- remediation commands
- repo slots and labels
- merge policy and live target ref within A2O-supported choices

## 3. Core-Owned Behavior

The project package does not redefine:

- task kind semantics
- phase semantics
- workspace topology
- rerun semantics
- evidence model
- scheduler behavior
- kanban provider implementation

## 4. Phase Commands

The public schema uses:

```yaml
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - your-ai-worker
          - "--schema"
          - "{{schema_path}}"
          - "--result"
          - "{{result_path}}"
```

A2O expands that command into the internal stdin-bundle protocol. The executor writes worker result JSON to `{{result_path}}`.

The stable script contract is defined in [55-project-script-contract.md](55-project-script-contract.md). Project scripts should use `A2O_*` worker environment names and request fields such as `slot_paths`, not private runtime metadata files.

## 5. Verification And Remediation

Verification and remediation commands are project-owned. They run in the materialized workspace and may use these placeholders:

- `{{workspace_root}}`
- `{{a2o_root_dir}}`
- `{{root_dir}}`

Remediation commands are used when verification fails and the package has a deterministic formatting or repair command.

## 6. Merge

Merge is configured with a project-owned policy and live target ref. A2O derives the actual merge target from task topology:

```yaml
runtime:
  phases:
    merge:
      policy: ff_only
      target_ref: refs/heads/main
```

Projects may choose policy and live target ref, but they do not choose `merge_to_live` or `merge_to_parent` inside `project.yaml`.

## 7. Presets

The 0.5.29 public package format is single-file `project.yaml`. Internal presets may remain implementation details, but package authors should not have to manage separate preset or manifest files.
