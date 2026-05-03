# テストフィードバックループ

レビュー前やリリース前に、どの範囲の検証を実行するか判断するときに読む。

## 現在のコストプロファイル

2026-05-03 に計測した結果:

| Suite | Command | Result |
|---|---|---|
| Ruby full suite | `bundle exec rspec --profile 20 --format progress` | 13 分 32 秒で成功。1335 examples |
| Ruby full suite, 3 example shards | `A2O_TEST_RUBY_SHARDS=3 tools/dev/test-core.sh` | 最長 Ruby shard 400 秒で成功。合計 1335 examples |
| Go full suite | `cd agent-go && go test ./...` | cached internal packages を含む状態で約 56 秒で成功 |
| Kanban Python suite | `python3 -m unittest discover -s tools/kanban/tests` | 約 1 秒で成功 |

このコストの多くは実際の integration coverage に由来する。Ruby suite と Go internal agent package は runtime、workspace、worker、process behavior を検証している。リリース検証では、これらを軽い確認に置き換えない。

## Core Parallel Check

coverage を落とさずに広めのローカル確認を行う場合は、以下を使う。

```sh
tools/dev/test-core.sh
```

このスクリプトは Ruby、Go、Kanban Python suite を並列実行し、デフォルトでは `.work/test-core/` にログを書く。ログ出力先は `A2O_TEST_LOG_DIR` で変更できる。

Ruby -> Go -> Python を順番に実行する無駄をなくすため、wall-clock time を短縮できる。assertion や package は削らない。

Ruby suite が local machine の律速になっており CPU に余裕がある場合は、Ruby spec file を deterministic shard に分割できる。

```sh
A2O_TEST_RUBY_SHARDS=2 tools/dev/test-core.sh
```

デフォルトでは、script が RSpec example を `--dry-run --format json` で検出し、各 shard に重複しない `file:line` selector を渡す。全体ではデフォルトの Ruby suite と同じ Ruby example を実行する。integration-heavy な spec は CPU と I/O を使うため、machine の余力がある範囲で shard 数を増やす。

custom Ruby command が RSpec JSON dry-run に対応できない場合は、file-level sharding に切り替える。

```sh
A2O_TEST_RUBY_SHARDS=2 A2O_TEST_RUBY_SHARD_GRANULARITY=file tools/dev/test-core.sh
```

診断やスクリプト自体の検証では、デフォルトコマンドを上書きできる。

```sh
A2O_TEST_RUBY_CMD='bundle exec rspec spec/a3/infra/worker_protocol_spec.rb' \
A2O_TEST_GO_CMD='cd agent-go && go test ./cmd/a3 -run TestWorkerPublicValidatorMatchesSharedProtocolFixtures' \
A2O_TEST_KANBAN_PY_CMD='python3 -m unittest tools.kanban.tests.test_cli.KanbaloneCliTest.test_normalize_task_watch_summary_preserves_parent_ref' \
tools/dev/test-core.sh
```

## Focused Checks

通常のチケット作業では、まず変更箇所に対応する最小の focused test を実行し、runtime、worker protocol、scheduler、project package validation、release surface など共有動作に触れた場合は広めの検証も実行する。

例:

```sh
bundle exec rspec spec/a3/infra/worker_protocol_spec.rb
cd agent-go && go test ./cmd/a3 ./cmd/a3-agent
python3 -m unittest discover -s tools/kanban/tests
```

## Release Validation

リリース検証では、release smoke script と real-task RC check も引き続き実行する。`tools/dev/test-core.sh` は core test の入口であり、runtime image、package、real-task release validation の代替ではない。
