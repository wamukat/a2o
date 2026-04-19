# A2O Project Surface

Audience: A2O designers, project package authors, implementers
Document type: project surface design

This document defines the small project-owned configuration surface. The project package should express product-specific knowledge without turning `project.yaml` into an unrestricted Engine configuration file.

## Goals

- Keep project-specific injection points minimal.
- Avoid carrying old product-specific complexity into Engine core.
- Make `project.yaml` a clear package config rather than a bag of runtime internals.
- Let A2O own task lifecycle, workspace topology, evidence, and merge semantics.

## Minimal Surface

Project packages may configure:

- implementation skill
- review skill
- parent review skill
- implementation/review executor commands
- verification commands
- remediation commands
- repo slots and labels
- merge target and policy within A2O-supported choices

## Core-Owned Behavior

The project package does not redefine:

- task kind semantics
- phase semantics
- workspace topology
- rerun semantics
- evidence model
- scheduler behavior
- kanban provider implementation

## Phase Commands

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

## Verification And Remediation

Verification and remediation commands are project-owned. They run in the materialized workspace and may use these placeholders:

- `{{workspace_root}}`
- `{{a2o_root_dir}}`
- `{{root_dir}}`

Remediation commands are used when verification fails and the package has a deterministic formatting or repair command.

## Merge

Merge is configured as a selection among A2O-supported behavior:

```yaml
runtime:
  phases:
    merge:
      target: merge_to_live
      policy: ff_only
      target_ref: refs/heads/main
```

Projects may choose target and policy, but they do not define new merge semantics inside `project.yaml`.

## Presets

The 0.5.0 public package format is single-file `project.yaml`. Internal presets may remain implementation details, but package authors should not have to manage separate preset or manifest files.
