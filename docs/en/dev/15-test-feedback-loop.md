# Test Feedback Loop

Use this document when choosing how much validation to run before review or release.

## Current Cost Profile

Measured on 2026-05-03:

| Suite | Command | Result |
|---|---|---|
| Ruby full suite | `bundle exec rspec --profile 20 --format progress` | passed in 13 minutes 32 seconds; 1335 examples |
| Ruby full suite, 3 example shards | `A2O_TEST_RUBY_SHARDS=3 tools/dev/test-core.sh` | passed with the slowest Ruby shard at 400 seconds; 1335 examples total |
| Go full suite | `cd agent-go && go test ./...` | passed in about 56 seconds with cached internal packages |
| Kanban Python suite | `python3 -m unittest discover -s tools/kanban/tests` | passed in about 1 second |

The cost is mostly real integration coverage. The Ruby suite and Go internal agent package exercise runtime, workspace, worker, and process behavior. Do not replace them with lighter checks for release validation.

## Core Parallel Check

For broad local confidence without dropping coverage, run:

```sh
tools/dev/test-core.sh
```

This runs the Ruby, Go, and Kanban Python suites in parallel and writes logs under `.work/test-core/` by default. Override the log directory with `A2O_TEST_LOG_DIR`.

This reduces wall-clock time by avoiding serial Ruby -> Go -> Python execution. It does not remove assertions or skip packages.

If the Ruby suite is the limiting path on a local machine with spare CPU, split the Ruby spec files into deterministic shards:

```sh
A2O_TEST_RUBY_SHARDS=2 tools/dev/test-core.sh
```

By default, the script discovers RSpec examples with `--dry-run --format json` and gives each shard a disjoint set of `file:line` selectors. Together, the shards execute the same Ruby examples as the default Ruby suite. Increase the shard count only while the machine still has enough CPU and I/O headroom, because over-sharding can make integration-heavy specs slower.

If a custom Ruby command cannot be discovered through RSpec JSON dry-run, fall back to file-level sharding:

```sh
A2O_TEST_RUBY_SHARDS=2 A2O_TEST_RUBY_SHARD_GRANULARITY=file tools/dev/test-core.sh
```

The default commands can be overridden for diagnostics or for validating the script itself:

```sh
A2O_TEST_RUBY_CMD='bundle exec rspec spec/a3/infra/worker_protocol_spec.rb' \
A2O_TEST_GO_CMD='cd agent-go && go test ./cmd/a3 -run TestWorkerPublicValidatorMatchesSharedProtocolFixtures' \
A2O_TEST_KANBAN_PY_CMD='python3 -m unittest tools.kanban.tests.test_cli.KanbaloneCliTest.test_normalize_task_watch_summary_preserves_parent_ref' \
tools/dev/test-core.sh
```

## Focused Checks

For normal ticket work, run the smallest focused test that covers the changed behavior first, then run a broader check when touching shared runtime, worker protocol, scheduler, project package validation, or release surfaces.

Examples:

```sh
bundle exec rspec spec/a3/infra/worker_protocol_spec.rb
cd agent-go && go test ./cmd/a3 ./cmd/a3-agent
python3 -m unittest discover -s tools/kanban/tests
```

## Release Validation

Release validation should still include the release smoke scripts and real-task RC checks. `tools/dev/test-core.sh` is a core test entrypoint, not a replacement for runtime image, package, or real-task release validation.
