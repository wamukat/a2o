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
- Kanban adapter contracts and generic protocol helpers, including `tools/kanban/cli.py`.
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
- `scripts/a3-projects/<project>/...` project manifests and project-injected launchers until external package loading is introduced.
- Short shell/Ruby launchers that pass project-injected config to `a3-engine`.
- `scripts/kanban/*` thin wrappers and project-local SoloBoard bootstrap helpers used by root `task kanban:*`.

Root glue must not become an A3 release dependency. Any root script that is required by a generic A3 install is a migration candidate into `a3-engine`.

## Current Root Script Classification

This section is the current file-level inventory for `scripts/a3`. Use it before moving or deleting any root script.

### Move toward `a3-engine`

- No tracked root files should remain under `scripts/a3`.
- Generic launcher surfaces now dispatch through `a3-engine/bin/a3 root-utility`; root Taskfile injects project paths and environment only.
- Individual operator wrappers such as `cleanup.rb`, `diagnostics.rb`, `reconcile.rb`, and `rerun_*` have been retired from root.
- Worker and generic smoke entrypoints should use `a3-engine/bin/a3 worker:*` commands instead of root wrappers.

| Root file | Classification | Action | Reason / dependency |
| --- | --- | --- | --- |
| `scripts/a3/run.rb` | Retired wrapper | Deleted after `a3-engine/bin/a3 root-utility` became the operator facade | Users must not invoke Ruby directly. Root Taskfile may set project-injected env, but the release boundary is packaged `a3` / `a3-agent`. |

### Retired from `scripts/a3`

| Retired root file | Classification | Action | Reason / dependency |
| --- | --- | --- | --- |
| `scripts/a3/cleanup.rb` | Retired wrapper | Deleted after operator logic moved to `a3-engine/lib/a3/operator/cleanup.rb` | Cleanup policy for issue workspace, runtime results, logs, quarantine, and disposable caches is generic A3 behavior. Project-specific storage roots remain arguments/config. |
| `scripts/a3/diagnostics.rb` | Retired wrapper | Deleted after operator logic moved to `a3-engine/lib/a3/operator/diagnostics.rb` | Live process / worker run / result / scheduler diagnostics are generic. Project names, storage dirs, and launcher paths remain injected. |
| `scripts/a3/reconcile.rb` | Retired wrapper | Deleted after operator logic moved to `a3-engine/lib/a3/operator/reconcile.rb` | Active-run reconciliation is core scheduler behavior. Project storage and command patterns remain injected. |
| `scripts/a3/rerun_workspace_support.rb` | Retired support library | Migrated to `a3-engine/lib/a3/operator/rerun_workspace_support.rb` | It defines generic issue workspace and quarantine path policy. Root scripts should require the engine library instead of keeping a root copy. |
| `scripts/a3/rerun_quarantine.rb` | Retired wrapper | Deleted after operator logic moved to `a3-engine/lib/a3/operator/rerun_quarantine.rb` | Quarantine mechanics are generic; allowed project build outputs must remain configurable. |
| `scripts/a3/rerun_readiness.rb` | Retired wrapper | Deleted after operator logic moved to `a3-engine/lib/a3/operator/rerun_readiness.rb` | Rerun readiness checks are generic runtime state inspection. Project kanban command working directory remains injected by project config. |
| `scripts/a3/launchd.rb` | Optional host service helper | Deleted with macOS LaunchAgent service entrypoints | This was not an `a3-agent` scheduler registration feature. It only supported root `a3:portal:scheduler:install/uninstall/reload/status` and was not required by the Docker A3 + host-local agent flow. |
| `scripts/a3/assert_a3_live_write_enabled.rb` | A3-owned safety guard, unreferenced | Deleted from root | It contained no Portal knowledge, but no current command used it. Reintroduce only as an A3-owned guard if a current A3 command needs it. |
| `scripts/a3/a3_stdin_bundle_worker.rb` | Retired worker wrapper | Deleted after `a3-engine/bin/a3 worker:stdin-bundle` became the worker entrypoint | The engine worker reads executor command templates and repo-scope aliases from project config. Portal labels such as `repo:starters` / `repo:ui-app` must not be hardcoded in A3 core. |
| `scripts/a3/a3_direct_canary_worker.rb` | Retired smoke wrapper | Deleted after `a3-engine/bin/a3 worker:direct-canary` became the smoke worker entrypoint | Legacy direct run-once entrypoints were retired. Direct canary behavior now lives behind the engine CLI. |
| `scripts/a3-projects/portal/agent_host_bundle_smoke.sh` | Portal runtime smoke harness | Moved out of `scripts/a3`; keep project-injected until generic smoke is parameterized into A3 Engine tests | It validates host-local agent coupling, but references the Portal compose bundle and synthetic repo shape. |
| `scripts/a3-projects/portal/agent_parent_topology_bundle_smoke.sh` | Portal runtime smoke harness with Portal mode | Moved out of `scripts/a3`; split later if a generic topology smoke is promoted into A3 Engine tests | It mixes generic parent/child topology with real Portal repo verification. |

### Keep as project-injected Portal glue

- `scripts/a3-projects/portal/config/portal/**`
- `scripts/a3-projects/portal/config/portal-dev/**`
- `scripts/a3-projects/portal/portal_remediation.rb`
- `scripts/a3-projects/portal/portal_verification.rb`
- `scripts/a3-projects/portal/bootstrap-task-maven-local-repo.sh`
- `scripts/a3-projects/portal/bootstrap-phase-support-maven.sh`
- `scripts/a3-projects/portal/runtime_agent_scheduler_run_once.sh`
- Portal-specific scheduler launcher / watch-summary wrappers while root Taskfile remains the Portal operator entrypoint.

| Root file | Classification | Action | Reason / dependency |
| --- | --- | --- | --- |
| `scripts/a3-projects/portal/config/portal/**` | Project package | Moved out of `scripts/a3`; keep root project package until external package loading exists | Contains Portal board, labels, repo aliases, command templates, verification/remediation hooks, and runtime manifest. |
| `scripts/a3-projects/portal/config/portal-dev/**` | Maintenance-only project package | Moved out of `scripts/a3`; keep until portal-dev surface is retired | Used for isolated maintenance compatibility. Do not promote into A3 release assets. |
| `scripts/a3-projects/portal/portal_runtime_surface.rb` | Portal root glue | Moved out of `scripts/a3`; keep until Taskfile/runtime package is moved | Defines Portal-specific manifest, storage, and scheduler launcher paths. |
| `scripts/a3-projects/portal/portal_scheduler_launcher.rb` | Portal root glue | Moved out of `scripts/a3`; keep as Portal operator entrypoint for now | It binds Portal storage, trigger labels, repo labels, worker script, and scheduler settings. |
| `scripts/a3-projects/portal/portal_watch_summary.rb` | Portal root glue | Moved out of `scripts/a3`; keep as Portal operator entrypoint for now | It binds Portal storage and kanban labels around A3 watch-summary. Generic watch formatting should live in A3, but Portal runtime binding stays injected. |
| `scripts/a3/prepare_portal_scheduler_launchd_config.rb` | Portal root glue | Deleted with macOS LaunchAgent service entrypoints | It only wrote the deleted Portal scheduler LaunchAgent plist. |
| `scripts/a3-projects/portal/prepare_portal_runtime_config.rb` | Portal root glue | Keep until Portal config is loaded as an external project package | It materializes project-injected shell env and working directory overrides for `doctor-env`, cleanup, and reconcile without tying the path to macOS LaunchAgent service support. |
| `scripts/a3-projects/portal/portal_verification.rb` | Project verification hook | Keep project-injected | Encodes Portal completion gates, repo slot commands, Maven local repo bootstrap, knowledge build, and parent/child verification rules. |
| `scripts/a3-projects/portal/portal_remediation.rb` | Project remediation hook | Keep project-injected | Encodes Portal remediation command (`task fmt:apply`) and slot expectations. |
| `scripts/a3-projects/portal/bootstrap-task-maven-local-repo.sh` | Project toolchain bootstrap | Keep project-injected | Maven local repository materialization is required for Portal's starter artifact flow. It is not a simple cache; it can contain starter build artifacts consumed by `ui-app`. |
| `scripts/a3-projects/portal/bootstrap-phase-support-maven.sh` | Project support-repo bootstrap | Keep project-injected | Installs the support `member-portal-starters` artifact into the issue-local Maven repo before `ui-app` verification. |
| `scripts/a3-projects/portal/rebuild-maven-seed-cache.sh` | Project/operator cache helper | Keep project-injected | It prepares a Portal Maven seed cache from the operator environment. A3 may define cache injection contracts, but not own Portal dependency contents. |
| `scripts/a3-projects/portal/runtime_agent_scheduler_run_once.sh` | Portal runtime canary launcher | Keep project-injected | It binds Docker A3 runtime, SoloBoard port, Portal manifest, host agent profile, and Portal worker script. |
| `scripts/a3-projects/portal/runtime_agent_scheduler_ref_candidates.py` | Portal runtime diagnostic helper | Keep project-injected, delete when no longer used | It queries Portal labels and repo mappings directly. |
| `scripts/a3-projects/portal/bootstrap_portal_dev_repos.rb` | Portal-dev maintenance bootstrap | Keep until portal-dev is retired | It materializes local Portal dev repos and branches; not A3 release logic. |
| `scripts/a3/bootstrap_a3_direct_repo_sources.rb` | Direct canary source bootstrap | Deleted with legacy direct canary source preparation | It referenced `member-portal-starters` and `member-portal-ui-app` and was only needed by retired direct canary preparation. |
| `scripts/a3/ensure_a3_direct_repo_sources.rb` | Direct canary source bootstrap wrapper | Deleted with `bootstrap_a3_direct_repo_sources.rb` | Same dependency and lifecycle as the direct canary source bootstrap. |

### Migration order

1. Native A3 CLI parity: add `a3-engine/bin/a3` commands for `cleanup`, `diagnostics`, `reconcile`, and `rerun_*`; root Taskfile behavior is preserved through `a3-engine/bin/a3 root-utility`, not a root Ruby wrapper.
2. Worker bridge extraction: replace root worker wrappers with `a3-engine/bin/a3 worker:stdin-bundle` and `worker:direct-canary`; keep Portal launcher config in the project package.
3. Smoke split: move synthetic host-agent and parent-topology smoke into A3 tests; keep real Portal full verification as project canary.
4. Portal package extraction: move `scripts/a3-projects/portal/**` into an external project package format once A3 can load project packages explicitly.

### Review checklist

- The moved file must not mention `Portal`, `OIDC`, `member-portal-*`, `repo:starters`, `repo:ui-app`, or Portal task names unless those values are supplied as config.
- A3-owned code may define filesystem contracts, but project-owned code supplies repo paths, command lines, labels, board names, Maven seed sources, and verification gates.
- Root wrappers may call A3 release assets, but A3 release assets must not call root wrappers.
- Maven seed/local-repo helpers are project-injected for Portal because starter build artifacts are part of the verification data flow, not just disposable dependency cache.
- Any migration must keep existing Taskfile entrypoints working until the replacement entrypoint is committed and tested.

### Kanban helper location

The generic kanban command contract belongs under `a3-engine/tools/kanban`. Root `scripts/kanban` is project/workspace glue. The abstraction boundary is:

- `a3-engine/tools/kanban/cli.py` and `a3-engine/tools/kanban/kanban_cli.py`: generic kanban CLI / adapter entrypoint used by A3 Engine.
- `scripts/kanban/cli.py`: thin wrapper for workspace Taskfile compatibility.
- `scripts/kanban/bootstrap_soloboard.py`: project/workspace bootstrap for Portal / OIDC / A3Engine boards and tags.
- `scripts/kanban/soloboard_smoke.py`: local compatibility smoke for the workspace SoloBoard instance.
- `scripts/kanban/soloboard_doctor.sh` and `scripts/kanban/soloboard_wait_ready.sh`: local SoloBoard runtime helpers.

Do not add a new top-level script namespace for a kanban backend unless it owns an independently shipped tool. Backend-specific helpers stay below `scripts/kanban`.

## Migration Rule

When adding a new script or config:

1. If it is needed by a generic A3 installation, add it to `a3-engine`.
2. If it mentions Portal / OIDC / repo names / project task commands, keep it outside A3 core and inject it through project config.
3. If it is a generic kanban command helper used by A3 Engine or `a3-agent`, place it under `a3-engine/tools/kanban`.
4. If it is a project-specific kanban bootstrap or local operator helper, keep it under root `scripts/kanban`.
5. If the only purpose is historical compatibility, delete it unless a current task or test proves it is still required.
