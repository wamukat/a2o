# Testing Policy Skill

- Start with the narrowest test that proves the changed behavior.
- Add broader tests when the change affects shared contracts, runtime state, migration behavior, or user-facing CLI output.
- Record commands exactly as run.
- If a test cannot be run, report the blocker and the residual risk.
- Do not weaken or remove existing tests to make a change pass.
