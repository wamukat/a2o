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
- Project-specific SoloBoard bootstrap helpers under `scripts/a3-projects/<project>/...`.

Root glue must not become an A3 release dependency. Any root script that is required by a generic A3 install is a migration candidate into `a3-engine`.

## Current Root Script Classification

This section is the current file-level inventory for `scripts/a3`. Use it before moving or deleting any root script.

### Move toward `a3-engine`

- No tracked root files should remain under `scripts/a3`.
- Generic root-local maintenance surfaces dispatch through `a3-engine/bin/a3 root-utility`; release-facing runtime surfaces dispatch through Docker A3 runtime `a3`.
- Individual operator wrappers such as `cleanup.rb`, `diagnostics.rb`, `reconcile.rb`, and `rerun_*` have been retired from root.
- Worker and generic validation entrypoints should use `a3-engine/bin/a3 worker:*` commands instead of root wrappers.

| Root file | Classification | Action | Reason / dependency |
| --- | --- | --- | --- |
| `scripts/a3/run.rb` | Retired wrapper | Deleted after `a3-engine/bin/a3 root-utility` became the operator facade | Users must not invoke Ruby directly. Root Taskfile may set project-injected env, but the release boundary is Docker A3 runtime command + Go `a3-agent` release binary. |

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
| `scripts/a3/a3_direct_validation_worker.rb` | Retired validation wrapper | Deleted after `a3-engine/bin/a3 worker:direct-validation` became the validation worker entrypoint | Legacy direct run-once entrypoints were retired. Direct validation behavior now lives behind the engine CLI. |
### Keep as project-injected Portal package

- `scripts/a3-projects/portal/inject/config/portal/**`
- `scripts/a3-projects/portal/inject/portal_remediation.rb`
- `scripts/a3-projects/portal/inject/portal_verification.rb`
- `scripts/a3-projects/portal/inject/bootstrap-task-maven-local-repo.sh`
- `scripts/a3-projects/portal/inject/bootstrap-phase-support-maven.sh`
- `scripts/a3-projects/portal/inject/config/kanban/soloboard-bootstrap.json`

| Root file | Classification | Action | Reason / dependency |
| --- | --- | --- | --- |
| `scripts/a3-projects/portal/inject/config/portal/**` | Project package | Moved out of `scripts/a3`; keep root project package until external package loading exists | Contains Portal board, labels, repo aliases, command templates, verification/remediation hooks, and runtime manifest. |
| `scripts/a3-projects/portal/inject/config/portal-dev/**` | Maintenance-only project package | Deleted | It was an isolated clone compatibility profile from earlier migration work. Current A3 runtime uses the live `portal` profile. |
| `scripts/a3-projects/portal/portal_runtime_surface.rb` | Portal root glue | Deleted | The legacy local scheduler/watch surface was retired. Docker runtime and engine root-utility commands are the current path. |
| `scripts/a3-projects/portal/portal_scheduler_launcher.rb` | Portal root glue | Deleted | The run-once path no longer launches through this wrapper, and reconcile observes `runtime/run_once.sh` instead of the retired local scheduler process. |
| `scripts/a3-projects/portal/portal_watch_summary.rb` | Portal root glue | Deleted | Watch summary is served through Docker runtime `a3 watch-summary`; generic formatting belongs in A3 Engine. |
| `scripts/a3/prepare_portal_scheduler_launchd_config.rb` | Portal root glue | Deleted with macOS LaunchAgent service entrypoints | It only wrote the deleted Portal scheduler LaunchAgent plist. |
| `scripts/a3-projects/portal/inject/portal_verification.rb` | Project verification hook | Keep project-injected | Encodes Portal completion gates, repo slot commands, Maven local repo bootstrap, knowledge build, and parent/child verification rules. |
| `scripts/a3-projects/portal/inject/portal_remediation.rb` | Project remediation hook | Keep project-injected | Encodes Portal remediation command (`task fmt:apply`) and slot expectations. |
| `scripts/a3-projects/portal/inject/bootstrap-task-maven-local-repo.sh` | Project toolchain bootstrap | Keep project-injected | Maven local repository materialization is required for Portal's starter artifact flow. It is not a simple cache; it can contain starter build artifacts consumed by `ui-app`. |
| `scripts/a3-projects/portal/inject/bootstrap-phase-support-maven.sh` | Project support-repo bootstrap | Keep project-injected | Installs the support `member-portal-starters` artifact into the issue-local Maven repo before `ui-app` verification. |
| `scripts/a3-projects/portal/inject/config/kanban/soloboard-bootstrap.json` | Project kanban bootstrap config | Keep project-injected | Board names, lanes, tags, and trigger labels are project/operator profile data, not A3 core knowledge. Generic bootstrap execution belongs to A3 Engine. |

### Keep as Portal support and verification harness

These files are not injected runtime hooks. `runtime/` contains Portal's current manual runtime launchers, `operator-tests/` is reserved for explicit validation entrypoints when such tests exist, and `maintenance/` contains operator maintenance helpers.

| Root file | Classification | Action | Reason / dependency |
| --- | --- | --- | --- |
| `scripts/a3-projects/portal/runtime/run_once.sh` | Portal runtime launcher | Keep as current Portal runtime surface behind `task a3:portal:runtime:run-once` | It binds Docker A3 runtime, SoloBoard port, Portal manifest, host `a3-agent` export, and Portal worker script for one manual runtime cycle. This is operational glue, not an operator test. |
| `scripts/a3-projects/portal/maintenance/prepare_portal_runtime_config.rb` | Portal root glue | Keep as support helper until Portal config is loaded as an external project package | It materializes project-injected shell env and working directory overrides for `doctor-env`, cleanup, and reconcile without tying the path to macOS LaunchAgent service support. |
| `scripts/a3-projects/portal/maintenance/rebuild-maven-seed-cache.sh` | Project/operator cache helper | Keep as maintenance, not runtime injection | It prepares a Portal Maven seed cache from the operator environment. A3 may define cache injection contracts, but not own Portal dependency contents. |
| `scripts/a3-projects/portal/runtime_agent_scheduler_ref_candidates.py` | Portal runtime diagnostic helper | Deleted | Dynamic candidate lookup was removed from `runtime/run_once.sh`; agent materialization now owns per-phase ref preparation. |
| `scripts/a3-projects/portal/maintenance/bootstrap_portal_dev_repos.rb` | Portal-dev maintenance bootstrap | Deleted | `portal-dev` was retired from the current runtime surface. |
| `scripts/a3/bootstrap_a3_direct_repo_sources.rb` | Direct validation source bootstrap | Deleted with legacy direct validation source preparation | It referenced `member-portal-starters` and `member-portal-ui-app` and was only needed by retired direct validation preparation. |
| `scripts/a3/ensure_a3_direct_repo_sources.rb` | Direct validation source bootstrap wrapper | Deleted with `bootstrap_a3_direct_repo_sources.rb` | Same dependency and lifecycle as the direct validation source bootstrap. |

### Migration order

1. Native A3 CLI parity: add `a3-engine/bin/a3` commands for `cleanup`, `diagnostics`, `reconcile`, and `rerun_*`; root Taskfile behavior is preserved through `a3-engine/bin/a3 root-utility`, not a root Ruby wrapper.
2. Worker bridge extraction: replace root worker wrappers with `a3-engine/bin/a3 worker:stdin-bundle` and `worker:direct-validation`; keep Portal launcher config in the project package.
3. Validation split: move synthetic host-agent and parent-topology validation into A3 tests; keep real Portal full verification as project validation.
4. Portal package extraction: move `scripts/a3-projects/portal/**` into an external project package format once A3 can load project packages explicitly.

### Review checklist

- The moved file must not mention `Portal`, `OIDC`, `member-portal-*`, `repo:starters`, `repo:ui-app`, or Portal task names unless those values are supplied as config.
- A3-owned code may define filesystem contracts, but project-owned code supplies repo paths, command lines, labels, board names, Maven seed sources, and verification gates.
- Root wrappers may call A3 release assets, but A3 release assets must not call root wrappers.
- Maven seed/local-repo helpers are project-injected for Portal because starter build artifacts are part of the verification data flow, not just disposable dependency cache.
- Any migration must keep existing Taskfile entrypoints working until the replacement entrypoint is committed and tested.

### Kanban helper location

The generic kanban command contract belongs under `a3-engine/tools/kanban`. A top-level root `scripts/kanban` namespace is not allowed because it obscures whether a helper is A3-owned or project-injected. The abstraction boundary is:

- `a3-engine/tools/kanban/cli.py` and `a3-engine/tools/kanban/kanban_cli.py`: generic kanban CLI / adapter entrypoint used by A3 Engine.
- `a3-engine/tools/kanban/soloboard_validation.py`: generic SoloBoard compatibility validation for the current kanban command contract.
- `a3-engine/tools/kanban/soloboard_doctor.sh` and `a3-engine/tools/kanban/soloboard_wait_ready.sh`: generic local SoloBoard runtime helpers.
- `a3-engine/tools/kanban/bootstrap_soloboard.py`: generic SoloBoard bootstrap runner. It reads project-injected board/lane/tag config and must not hardcode Portal / OIDC / A3Engine knowledge.
- `scripts/a3-projects/portal/inject/config/kanban/soloboard-bootstrap.json`: Portal workspace board/lane/tag config supplied to the generic bootstrap runner.

Do not add a new top-level script namespace for a kanban backend unless it owns an independently shipped tool. Generic backend helpers stay below `a3-engine/tools/kanban`; project bootstrap stays below the project package.

## Migration Rule

When adding a new script or config:

1. If it is needed by a generic A3 installation, add it to `a3-engine`.
2. If it mentions Portal / OIDC / repo names / project task commands, keep it outside A3 core and inject it through project config.
3. If it is a generic kanban command helper used by A3 Engine or `a3-agent`, place it under `a3-engine/tools/kanban`.
4. If it is a project-specific kanban bootstrap, keep it under the relevant `scripts/a3-projects/<project>/` package until external package loading exists.
5. If the only purpose is historical compatibility, delete it unless a current task or test proves it is still required.
