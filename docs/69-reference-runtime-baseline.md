# Reference Runtime Baseline

Date: 2026-04-17

This baseline proves A2O core runtime flows against the dedicated reference product suite.

The implementation and parent-review decisions in this baseline are deterministic on purpose. `tools/reference_validation/deterministic_worker.rb` applies known scenario changes and returns known review dispositions so the baseline isolates A2O runtime behavior from model variability. The exercised runtime surfaces are still real: SoloBoard pickup and transitions, branch namespace creation, agent-materialized workspace preparation, worker gateway transport, agent-side publication, verification command execution, child-to-parent merge, parent review handoff, parent verification, live merge, and evidence persistence.

## Runtime Shape

- SoloBoard: isolated board on `http://127.0.0.1:3481`
- Engine entrypoint: `ruby -Ilib bin/a3 execute-until-idle`
- Agent control plane: `ruby -Ilib bin/a3 agent-server`
- Agent runner: `.work/bin/a2o-agent`
- Worker gateway: `agent-http`
- Verification runner: `agent-http`
- Merge runner: `agent-http`
- Workspace mode: `agent-materialized`
- Branch namespace: product-specific `a2o-ref-*-baseline*`

The public host launcher now covers project bootstrap, kanban service operations, and foreground runtime execution. This baseline was recorded before that public wrapper existed, so its reproduction notes still show the internal engine CLI path.

## Passing Baselines

| Product | Board task(s) | Runtime phases | Result |
| --- | --- | --- | --- |
| TypeScript API/Web | `A2OReferenceTypeScript#9` | implementation, verification, merge | Done |
| Go API/CLI | `A2OReferenceGo#10` | implementation, verification, merge | Done |
| Python service | `A2OReferencePython#11` | implementation, verification, merge | Done |
| Multi-repo fixture | `A2OReferenceMultiRepo#1/#2/#3` | child implementation, child verification, child-to-parent merge, parent review, parent verification, parent merge | Done |

Evidence state was retained under `.work/reference-baseline/`. These files are runtime evidence for the engine/agent/kanban/verification/merge path, not evidence that an AI model independently solved the scenarios:

- `.work/reference-baseline/typescript-flow9/state/runs.json`
- `.work/reference-baseline/go-flow1/state/runs.json`
- `.work/reference-baseline/python-flow1/state/runs.json`
- `.work/reference-baseline/multi-flow4/state/runs.json`

## Fixes Captured By Baseline

- Reference board names must be branch-ref safe. Names with spaces produced invalid refs.
- Reference boards need the runtime lanes `Inspection` and `Merging`, not only user-facing planning lanes.
- `agent-materialized` implementation must run through `worker-gateway=agent-http`; local worker publication is correctly rejected.
- Single task materialization needs `--agent-support-ref SLOT=refs/heads/main` so the agent can create the first work branch from a known base.
- Agent HTTP server must ignore client disconnects while writing responses; otherwise an `ECONNRESET` can terminate the control plane and make later job fetches fail.
- Multi-repo package verification must remain a package-owned script while supporting materialized slot directory names.
- Multi-repo parent live merge target is `refs/heads/main`; the parent integration ref remains an internal source ref, not the final live target.

## Reproduction Notes

For each product:

1. Bootstrap the package board with `tools/kanban/bootstrap_soloboard.py`.
2. Create scenario tasks from `project-package/scenarios`.
3. Add trigger and repo labels from the package bootstrap config.
4. Start `agent-server` and `a2o-agent`.
5. Run `execute-until-idle` with:
   - `--worker-gateway agent-http`
   - `--verification-command-runner agent-http`
   - `--merge-runner agent-http`
   - `--agent-shared-workspace-mode agent-materialized`
   - `--agent-source-alias SLOT=ALIAS`
   - `--agent-source-path ALIAS=PATH`
   - `--agent-support-ref SLOT=refs/heads/main`

This is the baseline to rerun before and after refactoring tickets that touch runtime execution, workspace materialization, worker gateway, verification, merge, or package preset handling.
