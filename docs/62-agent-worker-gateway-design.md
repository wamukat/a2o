# Agent Worker Gateway Design

対象読者: A2O runtime 実装者 / agent 実装者 / reviewer
文書種別: protocol design

The agent worker gateway lets A2O Engine delegate project-local work to an `a2o-agent` process running in the host or project dev-env. This keeps project toolchains outside the runtime image while preserving Engine-owned orchestration.

## Goals

- Engine owns task selection, phase transitions, workspace metadata, evidence, and merge decisions.
- Agent owns project-local command execution in a materialized workspace.
- Project package supplies repo aliases, command profiles, required binaries, and task template expectations.
- Gateway payloads are explicit JSON contracts, not ad hoc shell argument bundles.

## Flow

1. Engine creates or updates a workspace for the task phase.
2. Engine publishes an agent job through the control plane.
3. `a2o-agent` pulls the job, materializes the requested repo slots, and runs the declared command.
4. Agent uploads structured result metadata and artifacts.
5. Engine parses the result, records evidence, transitions the task, and publishes or merges refs when the phase allows it.

## Workspace Metadata

Agent jobs include:

- task ref and phase
- parent/child relationship when applicable
- workspace id and branch namespace
- repo slot aliases
- source refs and support refs
- command profile and expected working directory
- artifact upload policy

The agent must not infer product-specific paths from global defaults. Paths come from the job payload and the project package used to create that payload.

## Command Execution

Project commands run agent-side. The gateway supports implementation workers, verification commands, merge commands, and diagnostic commands through the same control-plane shape.

The command runner records:

- exit status
- stdout/stderr summary
- changed files when the phase publishes edits
- declared evidence artifacts
- structured failure reason for blocked tasks

Verification commands are project package responsibility. Engine only interprets success, failure, blocked reason, and evidence metadata.

## Materialized Workspace Rules

- Repo slot names are stable package aliases, such as `app`, `repo_alpha`, or `repo_beta`.
- User-visible branch refs created by the current runtime use `refs/heads/a2o/...`. Existing `refs/heads/a3/...` refs are legacy compatibility data.
- Agent workspace paths are disposable and should not be used as durable project configuration.
- Generated runtime metadata may live under `.a3/` inside the materialized workspace for compatibility, but user-facing docs should not require users to edit it.

## Validation

The reference runtime baseline validates the gateway with:

- TypeScript single-repo implementation / verification / merge
- Go single-repo implementation / verification / merge
- Python single-repo implementation / verification / merge
- Multi-repo parent-child implementation, child merge, parent review, parent verification, and parent merge

See [69-reference-runtime-baseline.md](69-reference-runtime-baseline.md).
