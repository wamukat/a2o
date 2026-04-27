# メトリクスダッシュボード連携

A2O は Grafana やその他の dashboard server を runtime image に bundle しない。サポートする連携方針は out-of-core である。

1. A2O が task metrics を保存し、export する。
2. project-owned sync job が、その export を operator が選んだ dashboard data source に書き込む。
3. Grafana や BI tool が、その project-owned data source を読む。

これにより A2O は provider-neutral のままになり、dashboard service、Grafana plugin、renderer container、reporting schema を runtime の必須依存にしない。

## Export 入力

プロジェクトワークスペースで次のコマンドを実行する。

```sh
mkdir -p .work/a2o-metrics-dashboard

a2o runtime metrics list --format json \
  > .work/a2o-metrics-dashboard/metrics-list.json

a2o runtime metrics summary --group-by parent --format json \
  > .work/a2o-metrics-dashboard/metrics-summary-parent.json

a2o runtime metrics trends --group-by parent --format json \
  > .work/a2o-metrics-dashboard/metrics-trends-parent.json
```

dashboard を自動更新する場合は、同じコマンドを cron job、CI job、または project-package reporting script で実行する。

## Data source 境界

A2O は Grafana data source plugin を指定しない。プロジェクトごとに data source を 1 つ選び、adapter は A2O core の外に置く。選択肢は次のようなものがある。

- JSON export をプロジェクト既存の HTTP endpoint にコピーする。
- JSON/CSV export を project-owned SQLite、PostgreSQL、time-series database に取り込む。
- export file を object storage に配置し、Grafana や BI tool がその場所を読む。

adapter は [../dev/58-metrics-data-access.md](../dev/58-metrics-data-access.md) の JSON shape を source contract として扱う。`task_metrics.json` や SQLite table などの A2O runtime storage file を直接読まない。

## 推奨 dashboard panel

rollup には `metrics-summary-parent.json` を使う。

| Panel | Source fields |
| --- | --- |
| 親ごとの変更行数 | `group_key`, `lines_added`, `lines_deleted`, `files_changed` |
| 親ごとのテスト結果 | `group_key`, `tests_passed`, `tests_failed`, `tests_skipped` |
| 最新 line coverage | `group_key`, `latest_line_coverage`, `latest_timestamp` |

derived indicator には `metrics-trends-parent.json` を使う。

| Panel | Source fields |
| --- | --- |
| Rework rate | `group_key`, `rework_rate`, `rework_count`, `record_count` |
| Verification duration | `group_key`, `avg_verification_seconds`, `avg_total_seconds` |
| Token efficiency | `group_key`, `tokens_input`, `tokens_output`, `tokens_per_line_added` |
| Test failure rate | `group_key`, `test_failure_rate`, `tests_failed`, `tests_total` |
| Coverage trend | `group_key`, `latest_line_coverage`, `line_coverage_delta` |
| Unsupported indicators | `group_key`, `unsupported_indicators` |

`unsupported_indicators` に `blocked_rate` が含まれる場合、dashboard は 0 ではなく unavailable として表示する。A2O task metrics record は、blocked rate の算出に必要な全 task-state denominator をまだ持っていない。

## 運用メモ

- Grafana OSS は live operational dashboard に適している。定期 PDF/email report は Grafana Enterprise または別の reporting pipeline が必要になる場合がある。
- image rendering plugin や renderer container は resource-heavy になりうるため、A2O runtime の default には入れない。
- metrics export field を rename / remove する将来変更では、A2O release note で明示する。
- CLI/export では不足する concrete consumer requirement が出た場合に限り、runtime REST API や bundled dashboard profile の follow-up ticket を作る。
