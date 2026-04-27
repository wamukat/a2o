# Metrics Data Access Contract

Read this when deciding how stored task metrics should be consumed by dashboards, reports, or follow-up A2O features. Metrics collection and validation are defined in [55-project-script-contract.md](55-project-script-contract.md); this document defines the read-side contract.

## Decision

A2O should keep the v0.5.37 CLI/export surface as the stable metrics data-access boundary:

- `a2o metrics list --format json`
- `a2o metrics list --format csv`
- `a2o metrics summary --format json`
- `a2o metrics summary --group-by parent --format json`
- `a2o metrics trends --format json`
- `a2o metrics trends --group-by parent --format json`
- host wrapper equivalents under `a2o runtime metrics ...`

A2O should not add a runtime REST API or bundled dashboard server until a concrete consumer proves the CLI/export contract is insufficient. External dashboards should consume JSON/CSV exports directly, or a project-owned sync job should copy those exports into the dashboard database.

This keeps the runtime small, avoids another long-running public API surface, and lets metrics reporting evolve through versioned export records first.

## Stable JSON Shapes

`metrics list --format json` returns an array of task metrics records. Each record is the persisted form of `A3::Domain::TaskMetricsRecord`:

```json
[
  {
    "task_ref": "A2O#281",
    "parent_ref": "A2O#226",
    "timestamp": "2026-04-27T06:18:00Z",
    "code_changes": { "lines_added": 12, "lines_deleted": 3, "files_changed": 2 },
    "tests": { "passed_count": 8, "failed_count": 0, "skipped_count": 1 },
    "coverage": { "line_percent": 82.5 },
    "timing": {},
    "cost": {},
    "custom": {}
  }
]
```

Consumers must treat unknown keys inside section objects as project-owned extension data. Consumers should tolerate missing section fields and `null` values.

`metrics summary --format json` returns an array of summary entries:

```json
[
  {
    "group_key": "A2O#226",
    "record_count": 3,
    "task_count": 3,
    "parent_count": 1,
    "latest_timestamp": "2026-04-27T06:18:00Z",
    "lines_added": 42,
    "lines_deleted": 5,
    "files_changed": 7,
    "tests_passed": 20,
    "tests_failed": 0,
    "tests_skipped": 1,
    "latest_line_coverage": 82.5
  }
]
```

With `--group-by task`, `group_key` is the task ref. With `--group-by parent`, `group_key` is `parent_ref` when present and falls back to `task_ref` for standalone tasks.

`metrics trends --format json` returns derived indicators calculated from stored metrics records:

```json
[
  {
    "group_key": "A2O#226",
    "record_count": 3,
    "task_count": 3,
    "parent_count": 1,
    "latest_timestamp": "2026-04-27T06:18:00Z",
    "lines_added": 42,
    "tests_total": 21,
    "tests_failed": 1,
    "test_failure_rate": 0.047619047619047616,
    "avg_verification_seconds": 120.0,
    "avg_total_seconds": 600.0,
    "rework_count": 1,
    "rework_rate": 0.3333333333333333,
    "tokens_input": 4000,
    "tokens_output": 750,
    "tokens_per_line_added": 113.0952380952381,
    "latest_line_coverage": 82.5,
    "line_coverage_delta": 2.5,
    "unsupported_indicators": ["blocked_rate"]
  }
]
```

`metrics trends` defaults to `--group-by all`. It also accepts `--group-by task` and `--group-by parent`. Indicators that cannot be computed from task metrics records are listed in `unsupported_indicators` instead of being silently omitted.

## CSV Contract

`metrics list --format csv` is the spreadsheet-friendly mirror of list JSON. It includes these headers:

```text
task_ref,parent_ref,timestamp,code_changes,tests,coverage,timing,cost,custom
```

The section columns contain JSON objects encoded as CSV fields. CSV is for reporting tools and manual analysis; programmatic consumers should prefer JSON.

## Compatibility Rules

- Existing list and summary fields are additive-stable: do not rename or remove them without a migration note and release announcement.
- New fields may be added to JSON records or summary entries.
- New CLI subcommands such as `metrics trends` may build on these records, but must not change the default list/summary output shape.
- If a future REST API is added, it should expose the same JSON shapes first, then add HTTP-specific pagination or filtering.
- Runtime storage layout is not a public read contract. Consumers should use CLI/export output, not read `task_metrics.json` or SQLite tables directly.

## Non-goals

- No dashboard server in A2O runtime core for this phase.
- No bundled Grafana provisioning. A2O#308 documents the out-of-core dashboard integration model in [../user/60-metrics-dashboard.md](../user/60-metrics-dashboard.md).
- No provider-specific BI/report schema in core.
- No REST API for v0.5.37 follow-up work unless A2O#306 is reopened with a concrete consumer requirement.

## Follow-up Ticket Guidance

- A2O#307 implements trends and derived indicators as CLI/export features over the stable list JSON records.
- A2O#308 documents Grafana as an external consumer of JSON/CSV exports or a project-owned copied database. It does not assume a runtime REST API exists.
- A2O#226 and GitHub #16 remain open until the trends and dashboard decisions are completed or explicitly descoped.
