# Japanese Conservative Prompt Pack

This prompt pack is a small baseline for A2O project packages that operate mainly in Japanese. Copy `prompts/` and `skills/` into a project package, then merge `project.yaml.snippet` into `project.yaml`. If `project.yaml` already has a `runtime:` section, copy only the snippet's inner `prompts:` block under that existing `runtime:`.

The split is intentional:

- `prompts/system.md`: project-wide language, tone, and safety posture.
- `prompts/<phase>.md`: short phase stance and decision policy.
- `skills/*.md`: reusable procedures and checklists.
- ticket body/comments: task-specific acceptance criteria, constraints, and evidence requirements.

The files are conservative. They do not override A2O worker schemas, workspace boundaries, branch policy, review gates, verification, or Kanban state transitions.
