# Container Distribution And Project Runtime

A2O is distributed as a Docker runtime image, host launcher, project package, and `a2o-agent`. Users should not assemble long internal Engine command lines or runtime shell scripts.

## Artifacts

- Runtime image: Engine CLI, compose assets, host install assets, and agent release binaries.
- Host launcher: `a2o`, a thin Go binary that controls the runtime image from the host.
- Agent: `a2o-agent`, which runs project commands on the host or in a project dev environment.
- Project package: package identity, kanban bootstrap data, repo slots, runtime parameters, agent requirements, and task templates.

The runtime image still contains `a3` and `.a3` compatibility paths internally. Public user surfaces use `a2o` and `a2o-agent`.

The `a2o --help` output inside the runtime container is container-entrypoint help, not the full host launcher help. Normal operations such as `a2o project template`, `a2o project bootstrap`, `a2o kanban ...`, and `a2o runtime ...` are run through the host launcher installed by `a2o host install`.

## Runtime Shape

A2O treats one project package as one runtime instance.

Bootstrap creates `.work/a2o/runtime-instance.json` from the project package. Later `a2o kanban ...`, `a2o agent install`, and `a2o runtime ...` commands discover that instance config from the current directory upward.

```sh
a2o project bootstrap
a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent
a2o kanban up
a2o runtime watch-summary
a2o runtime run-once
```

Use `a2o project bootstrap --package DIR` when the package is not under `./project-package` or `./a2o-project`.

`a2o runtime up` and `down` manage only container lifecycle. Use `a2o runtime start` when task processing should run as a resident scheduler.

## Responsibility Boundary

A2O Engine owns:

- kanban service lifecycle
- task polling and transition
- workspace and branch namespace management
- worker gateway and agent job queue
- verification and merge orchestration
- evidence retention

The project package owns:

- project and kanban board name
- repo slot aliases and source paths
- trigger labels and task templates
- verification/build/test commands
- required agent-side toolchains
- project-specific hook scripts when declarative commands are insufficient

The project package does not own:

- Engine runtime loop scripts
- Docker compose files for A2O core services
- kanban provider API wrappers
- agent materializer configuration scripts
- release asset export logic

## Release 0.5.2 Surface

A2O 0.5.2 is released as a local-first runtime image plus host launcher and agent package. The standard validation surface is the reference product suite: SoloBoard pickup and transitions, agent-materialized workspaces, agent HTTP worker gateway, verification, merge, parent-child flow, watch summary, describe-task diagnostics, and evidence persistence.

The public launcher covers host install, check-only upgrade planning, project bootstrap, kanban service lifecycle, kanban diagnosis, URL discovery, agent install, runtime container up/down, one-shot runtime execution, foreground runtime loop, resident scheduler start/stop/status, runtime diagnosis, multi-task watch summary, and task/run observability.

## Operator Notes

- Keep project toolchains out of the runtime image.
- Keep branch namespaces instance-specific.
- Treat `.work/a2o/` as disposable runtime output.
- Existing `.a3/runtime-instance.json` is read only as a compatibility fallback.
- `.a3/` directories inside materialized repo workspaces are internal agent metadata.
- Prefer project package declarations over hard-coded Engine defaults.
