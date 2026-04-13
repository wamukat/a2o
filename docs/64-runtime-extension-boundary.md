# A3 Runtime Extension Boundary

対象読者: A3 maintainer / project integrator
文書種別: design rule

## Purpose

A3 release assets are managed in the `a3-engine` repository. Workspace root files are allowed only as project integration glue. If a file is required to ship A3 itself, it belongs under `a3-engine`. If a file contains Portal / OIDC / customer project knowledge, it must be injected as project runtime configuration instead of becoming A3 core.

## Boundary

### A3-owned

These belong in `a3-engine`:

- A3 Engine Ruby code and CLI.
- Go `a3-agent` source, build scripts, installer scripts, and release packaging.
- Generic runtime Docker assets, for example `docker/a3-runtime/Dockerfile`.
- Generic compose templates for A3 runtime + bundled kanban, when they do not encode a product repo layout.
- Kanban adapter contracts and generic protocol expectations.
- Workspace / branch / merge / artifact / cleanup contracts that are independent of a project.

### Project-injected

These must be supplied by the project workspace, project package, or operator profile:

- Project IDs, board names, lane names, labels, and trigger labels.
- Repo aliases and local paths.
- Repo-specific commands such as `task ops:flow:standard`, `task test:nullaway`, Maven bootstrap, knowledge catalog build, or Portal remediation.
- Project-specific runtime env such as `A3_ROOT_DIR`, `JAVA_HOME`, `A3_MAVEN_*`, and toolchain setup.
- Product-specific helper scripts such as Portal verification / remediation / Maven local repository bootstrap.
- Notification hooks and operator-specific AI command templates.

### Root workspace glue

The root workspace may keep thin glue only while this repository is used as a Portal integration workspace:

- `Taskfile.yml` entries that bind A3 Engine, SoloBoard, and Portal repos together.
- `scripts/a3/config/<project>/...` project manifests until they are moved into a project package format.
- Short shell/Ruby launchers that pass project-injected config to `a3-engine`.
- `scripts/kanban/*` local kanban CLI and SoloBoard bootstrap helpers used by root `task kanban:*`.

Root glue must not become an A3 release dependency. Any root script that is required by a generic A3 install is a migration candidate into `a3-engine`.

## Current Root Script Classification

### Move toward `a3-engine`

- Generic launcher surfaces currently in `scripts/a3/run.rb`, `cleanup.rb`, `diagnostics.rb`, `reconcile.rb`, `rerun_*`, and `launchd.rb` should be retired or migrated into A3 CLI commands.
- Generic smoke harness pieces should either become A3 Engine tests or be deleted after host-local scheduler validation is stable.

### Keep as project-injected Portal glue

- `scripts/a3/config/portal/**`
- `scripts/a3/config/portal-dev/**`
- `scripts/a3/portal_remediation.rb`
- `scripts/a3/portal_verification.rb`
- `scripts/a3/bootstrap-task-maven-local-repo.sh`
- `scripts/a3/bootstrap-phase-support-maven.sh`
- `scripts/a3/runtime_agent_scheduler_run_once.sh`
- Portal-specific scheduler launcher / watch-summary wrappers while root Taskfile remains the Portal operator entrypoint.

### Kanban helper location

SoloBoard-specific helper scripts belong under `scripts/kanban`, not a separate `scripts/soloboard` directory. The abstraction boundary is:

- `scripts/kanban/cli.py` and `scripts/kanban/kanban_cli.py`: kanban CLI / adapter entrypoint.
- `scripts/kanban/bootstrap_soloboard.py`: SoloBoard backend bootstrap implementation.
- `scripts/kanban/soloboard_smoke.py`: SoloBoard compatibility smoke.
- `scripts/kanban/soloboard_doctor.sh` and `scripts/kanban/soloboard_wait_ready.sh`: local SoloBoard runtime helpers.

Do not add a new top-level script namespace for a kanban backend unless it owns an independently shipped tool. Backend-specific helpers stay below `scripts/kanban`.

## Migration Rule

When adding a new script or config:

1. If it is needed by a generic A3 installation, add it to `a3-engine`.
2. If it mentions Portal / OIDC / repo names / project task commands, keep it outside A3 core and inject it through project config.
3. If it is a kanban backend helper, place it under `scripts/kanban` and keep A3 domain code dependent only on the kanban command contract.
4. If the only purpose is historical compatibility, delete it unless a current task or test proves it is still required.
