# Metrics Dashboard Integration

A2O does not bundle Grafana or another dashboard server in the runtime image. The supported integration path is out-of-core:

1. A2O stores and exports task metrics.
2. A project-owned sync job writes those exports into the dashboard data source chosen by the operator.
3. Grafana or another BI tool reads that project-owned data source.

This keeps A2O provider-neutral and avoids making a dashboard service, Grafana plugins, renderer containers, or reporting schemas mandatory runtime dependencies.

## Export Inputs

Run these commands from the project workspace:

```sh
mkdir -p .work/a2o-metrics-dashboard

a2o runtime metrics list --format json \
  > .work/a2o-metrics-dashboard/metrics-list.json

a2o runtime metrics summary --group-by parent --format json \
  > .work/a2o-metrics-dashboard/metrics-summary-parent.json

a2o runtime metrics trends --group-by parent --format json \
  > .work/a2o-metrics-dashboard/metrics-trends-parent.json
```

Use the same commands in a cron job, CI job, or project-package reporting script when the dashboard should refresh automatically.

## Data Source Boundary

A2O does not prescribe the Grafana data source plugin. Choose one data source per project and keep the adapter outside A2O core. Common options are:

- copy JSON exports to an HTTP endpoint already used by the project;
- load JSON/CSV exports into a project-owned SQLite, PostgreSQL, or time-series database;
- publish the exported files to object storage and configure Grafana or the BI tool to read that location.

The adapter should treat the JSON shapes from [../dev/58-metrics-data-access.md](../dev/58-metrics-data-access.md) as the source contract. It should not read A2O runtime storage files such as `task_metrics.json` or SQLite tables directly.

## Suggested Dashboard Panels

Use `metrics-summary-parent.json` for rollups:

| Panel | Source fields |
| --- | --- |
| Lines changed by parent | `group_key`, `lines_added`, `lines_deleted`, `files_changed` |
| Test results by parent | `group_key`, `tests_passed`, `tests_failed`, `tests_skipped` |
| Latest line coverage | `group_key`, `latest_line_coverage`, `latest_timestamp` |

Use `metrics-trends-parent.json` for derived indicators:

| Panel | Source fields |
| --- | --- |
| Rework rate | `group_key`, `rework_rate`, `rework_count`, `record_count` |
| Verification duration | `group_key`, `avg_verification_seconds`, `avg_total_seconds` |
| Token efficiency | `group_key`, `tokens_input`, `tokens_output`, `tokens_per_line_added` |
| Test failure rate | `group_key`, `test_failure_rate`, `tests_failed`, `tests_total` |
| Coverage trend | `group_key`, `latest_line_coverage`, `line_coverage_delta` |
| Unsupported indicators | `group_key`, `unsupported_indicators` |

If `unsupported_indicators` contains `blocked_rate`, the dashboard should show it as unavailable rather than zero. A2O task metrics records do not currently include the full task-state denominator required to compute blocked rate.

## Operational Notes

- Grafana OSS is suitable for live operational dashboards. Formal scheduled PDF/email reporting may require Grafana Enterprise or a separate reporting pipeline.
- Image rendering plugins and renderer containers can be resource-heavy. Keep them outside the default A2O runtime.
- A2O release notes must mention any future change that renames or removes metrics export fields.
- If a project proves that CLI/export is not enough, open a follow-up ticket with the concrete consumer requirement before adding a runtime REST API or bundled dashboard profile.
