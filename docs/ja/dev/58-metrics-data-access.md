# メトリクスデータアクセス契約

保存済みタスクメトリクスを dashboard、report、A2O の後続機能から読む方法を決めるときに読む。メトリクス収集と validation は [55-project-script-contract.md](55-project-script-contract.md) で定義し、この文書では read 側の契約を定義する。

## 方針

A2O は v0.5.37 で導入した CLI/export 面を、安定したメトリクスデータアクセス境界として扱う。

- `a2o metrics list --format json`
- `a2o metrics list --format csv`
- `a2o metrics summary --format json`
- `a2o metrics summary --group-by parent --format json`
- host wrapper の `a2o runtime metrics ...`

具体的な consumer が CLI/export 契約では不足すると示すまでは、runtime REST API や dashboard server は追加しない。外部 dashboard は JSON/CSV export を直接読むか、project-owned sync job が export を dashboard 用 database にコピーする。

これにより runtime を小さく保ち、長期維持が必要な公開 API surface を増やさず、まずは versioned export record を中心に reporting を発展させる。

## 安定 JSON 形状

`metrics list --format json` は task metrics record の配列を返す。各 record は `A3::Domain::TaskMetricsRecord` の persisted form である。

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

consumer は section object 内の未知 key を project-owned extension data として扱う。section field の欠落や `null` は許容する。

`metrics summary --format json` は summary entry の配列を返す。

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

`--group-by task` では `group_key` は task ref になる。`--group-by parent` では `parent_ref` があればそれを使い、単独 task では `task_ref` に fallback する。

## CSV 契約

`metrics list --format csv` は list JSON の spreadsheet 向け mirror である。header は次の通り。

```text
task_ref,parent_ref,timestamp,code_changes,tests,coverage,timing,cost,custom
```

section column には JSON object を CSV field として入れる。CSV は reporting tool と手動分析向けであり、programmatic consumer は JSON を優先する。

## 互換性ルール

- 既存の list / summary field は additive-stable とする。rename / remove する場合は migration note と release announcement を必要とする。
- JSON record や summary entry への field 追加は許容する。
- `metrics trends` のような新 CLI subcommand はこれらの record を利用してよいが、既存 list / summary の default output shape を変更しない。
- 将来 REST API を追加する場合も、まず同じ JSON shape を公開し、その上で HTTP 固有の pagination / filtering を追加する。
- runtime storage layout は公開 read 契約ではない。consumer は `task_metrics.json` や SQLite table を直接読まず、CLI/export output を使う。

## 非ゴール

- この段階では A2O runtime core に dashboard server を持たない。
- A2O#308 が運用モデルを確認するまで、Grafana provisioning を bundle しない。
- core に provider 固有の BI/report schema を持たない。
- 具体的な consumer 要件で A2O#306 を再検討するまでは、v0.5.37 follow-up として REST API は実装しない。

## 後続チケットへの指針

- A2O#307 は stable list JSON record の上に CLI/export feature として trends / derived indicators を実装する。
- A2O#308 は Grafana を JSON/CSV export または project-owned copied database の外部 consumer として評価する。runtime REST API が存在する前提にしない。
- A2O#226 と GitHub #16 は、trends と dashboard の判断が完了するか明示的に descoped されるまで open のままにする。
