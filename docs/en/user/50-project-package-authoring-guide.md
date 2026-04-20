# Project Package Authoring Guide

Use this guide when designing or reviewing an A2O project package. The schema document explains valid fields. This guide explains where each responsibility belongs.

## Package Boundary

A2O is a generic orchestration engine. It owns kanban orchestration, workspace creation, phase execution, verification/remediation orchestration, merge orchestration, and evidence recording.

The project package owns product-specific decisions:

- repository slots and kanban labels
- AI worker commands
- implementation and review skills
- build, test, verification, and remediation commands
- project-specific coding rules
- optional knowledge catalog commands
- task templates used by humans to create board tasks

A2O does not infer product policy from source code. If a worker needs a rule, command, or repository boundary, put it in the project package.

## Recommended Layout

```text
project-package/
  README.md
  project.yaml
  commands/
  skills/
    implementation/
    review/
  task-templates/
  tests/
    fixtures/
```

`project.yaml` is the only public package configuration file. It declares package identity, kanban selection, repository slots, agent prerequisites, runtime phases, verification/remediation commands, and merge policy.

`commands/` contains project-owned scripts called by runtime phases. Keep production commands and test fixtures clearly separated. Scripts in `commands/` should be safe to run for real tasks.

`skills/` contains project rules passed to AI workers. Skills should be short, concrete, and specific to the phase that uses them.

`task-templates/` contains human-facing task templates. A2O does not enqueue them automatically.

For multi-repo parent-child workflows, write task templates with explicit repo labels. A parent task that affects two repositories should carry both repo labels, for example `repo:catalog` and `repo:storefront`. Avoid synthetic aggregate labels that mean "all repos" or "both repos".

`tests/fixtures/` contains deterministic workers, fake inputs, or package validation fixtures. Runtime production config should not reference this directory.

## Production Config And Test Fixtures

Keep `project.yaml` for normal operation. Do not point production implementation/review phases at deterministic fixture workers.

If a package needs a test profile, keep it explicit:

- use a separate config such as `project-test.yaml`
- keep fixture workers under `tests/fixtures/`
- name verification fixtures so they cannot be mistaken for production commands
- document how to run the test profile

Validate the alternate profile explicitly:

```sh
a2o project validate --package ./project-package --config project-test.yaml
```

Run it explicitly when you need a focused test profile:

```sh
a2o runtime run-once --project-config project-test.yaml
```

Do not use `--project-config` for the resident scheduler unless the alternate config is intended to process real board tasks.

The normal package path should answer a simple question: "What will run when a real board task is selected?"

## Worker Protocol

Implementation, review, and parent review phases run through an executor command declared in `runtime.phases.<phase>.executor.command`.

The command receives a worker request bundle on stdin and writes the worker result JSON to `{{result_path}}`. A typical command looks like:

```yaml
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
```

Use these rules:

- Treat `{{schema_path}}`, `{{result_path}}`, `{{workspace_root}}`, `{{a2o_root_dir}}`, and `{{root_dir}}` as the public placeholders.
- Treat the worker request JSON and `A2O_*` environment variables as the stable runtime contract.
- Do not read private `.a3` metadata or generated launcher files from project scripts.
- Make worker failures actionable: explain which command failed, which repo/workspace was involved, and what the user should fix.

Generate a minimal worker with:

```sh
a2o worker scaffold --language python --output ./project-package/commands/a2o-worker.py
```

Then reference it from `runtime.phases.<phase>.executor.command`:

```yaml
command:
  - ./project-package/commands/a2o-worker.py
  - "--schema"
  - "{{schema_path}}"
  - "--result"
  - "{{result_path}}"
```

When developing a custom worker, save one worker request and result pair and validate it with:

```sh
a2o worker validate-result --request request.json --result result.json
```

The validator reports concrete missing keys, type errors, and `task_ref` / `run_ref` / `phase` mismatches before runtime execution. If your executor uses configured review scopes or repo-scope aliases, pass the same public values with repeated `--review-scope SCOPE` and `--repo-scope-alias FROM=TO`.

## Verification And Remediation

Verification commands prove the task result. Remediation commands may format code or perform project-approved cleanup before verification retries.

Good verification commands are deterministic and scoped:

- run the smallest command that proves the changed surface
- print enough context to diagnose failures
- exit non-zero when the task is not ready
- avoid hidden network or global machine dependencies when possible

If verification differs by parent/child/single task or by repo slot, keep that policy visible in `project.yaml` with command variants. Prefer a small default command and add only the exceptional cases:

```yaml
runtime:
  phases:
    verification:
      commands:
        default:
          - app/project-package/commands/verify-all.sh
        variants:
          task_kind:
            parent:
              phase:
                verification:
                  - app/project-package/commands/verify-parent.sh
```

Good remediation commands are conservative:

- format or regenerate known project artifacts
- avoid changing product behavior
- avoid committing, pushing, or editing kanban state

## Phase Skills

Skills are project-owned instructions for workers. Keep them focused on decisions the worker cannot infer safely.

Implementation skills should cover:

- repository boundaries and editable paths
- coding rules
- verification expectations
- when to use project knowledge commands
- what evidence to record

Review skills should cover:

- what counts as a finding
- expected verification evidence
- public API, SPI, migration, and documentation checks
- how to report residual risk

Parent review skills should cover multi-repo integration:

- how child outputs are combined
- which integration checks must pass before publishing
- merge readiness checks
- evidence expected before merge

Use the language your maintainers will actually maintain. A Japanese project package can use Japanese skills.

## Knowledge Catalogs

A2O does not require a knowledge catalog and does not depend on a specific catalog implementation.

If a project has one, expose it as project-owned commands or Taskfile entries and describe them in the relevant skills. Prefer narrow, task-specific queries over open-ended exploration.

Use the catalog differently by workflow stage:

- Planning and task decomposition may use broader catalog queries. Summarize relevant findings in the kanban task so runtime workers do not need to rediscover the same context.
- Implementation workers should receive or run only task-specific queries. Give them the command name, expected query shape, and the reason to use it.
- Review and parent review workers should use catalog queries to check changed API/SPI surfaces, repository boundaries, product rules, and integration assumptions related to the diff.
- Do not require MCP. A project-owned CLI, script, or Taskfile query is enough when it is deterministic and documented in the package.

Use knowledge results as supporting context. Source code, docs, tests, and verification results remain authoritative.

## Review Checklist

Before using a package for real tasks, check:

- `project.yaml` is the only public config file.
- `a2o project lint --package ./project-package` has no blocked findings.
- A2O-owned lanes and internal labels are not hand-authored in package config.
- `agent.required_bins` includes the product toolchain and worker executable.
- Production phases do not call `tests/fixtures/`.
- Verification commands fail clearly and print useful diagnostics.
- Remediation commands cannot make broad unintended changes.
- Skills state repo boundaries, review criteria, and evidence expectations.
- Generated files stay under `.work/a2o/`.
- User-facing docs and commands use A2O names.
