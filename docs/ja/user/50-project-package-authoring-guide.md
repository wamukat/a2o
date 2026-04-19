# Project Package Authoring Guide（project package 作成ガイド）

この guide は、A2O の project package を設計・レビューするときに使う。Schema doc は有効な field を説明する。この guide は、どの責務をどこに置くべきかを説明する。

## Package Boundary（package の境界）

A2O は汎用 orchestration engine である。A2O は kanban orchestration、workspace 作成、phase 実行、verification/remediation orchestration、merge orchestration、evidence 記録を担当する。

Project package は product 固有の判断を担当する。

- repository slot と kanban label
- AI worker command
- implementation / review skill
- build、test、verification、remediation command
- project 固有 coding rule
- 任意の knowledge catalog command
- 人間が board task を作るための task template

A2O は source code から product policy を自動推測しない。Worker が rule、command、repository boundary を必要とするなら、project package に明示する。

## Recommended Layout（推奨 layout）

```text
project-package/
  README.md
  project.yaml
  commands/
  skills/
    implementation/
    review/
  task-templates/
  tests/
    fixtures/
```

`project.yaml` は唯一の公開 package config である。Package identity、kanban selection、repository slot、agent prerequisite、runtime phase、verification/remediation command、merge policy を宣言する。

`commands/` には runtime phase から呼ぶ project-owned script を置く。Production command と test fixture は明確に分ける。`commands/` に置く script は、実 task で実行されてもよいものにする。

`skills/` には AI worker に渡す project rule を置く。Skill は短く、具体的で、利用する phase に合わせて書く。

`task-templates/` には人間向け task template を置く。A2O は task template を自動投入しない。

`tests/fixtures/` には deterministic worker、fake input、package validation fixture を置く。Production 用 runtime config からこの directory を参照してはならない。

## Production Config And Test Fixtures（通常 config と test fixture）

`project.yaml` は通常運用用に保つ。Production の implementation/review phase から deterministic fixture worker を呼ばない。

Package が test profile を必要とする場合は、明示的に分ける。

- `project-test.yaml` のような別 config を使う。
- fixture worker は `tests/fixtures/` 配下に置く。
- verification fixture は production command と間違えない名前にする。
- test profile の実行方法を docs に書く。

通常 package は「実 board task が選択されたとき、何が実行されるのか」に一目で答えられる状態にする。

## Worker Protocol（worker protocol）

Implementation、review、parent review phase は `runtime.phases.<phase>.executor.command` に宣言した executor command 経由で実行される。

Command は worker request bundle を stdin で受け取り、worker result JSON を `{{result_path}}` に書く。典型的な command は次の形である。

```yaml
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
```

次の rule に従う。

- `{{schema_path}}`、`{{result_path}}`、`{{workspace_root}}`、`{{a2o_root_dir}}`、`{{root_dir}}` を公開 placeholder として扱う。
- Worker request JSON と `A2O_*` environment variables を stable runtime contract として扱う。
- Project script から private `.a3` metadata や generated launcher file を読まない。
- Worker failure は actionable にする。どの command が失敗したか、どの repo/workspace が関係したか、利用者が何を直すべきかを説明する。

最小 worker は次の command で生成できる。

```sh
a2o worker scaffold --language python --output ./project-package/commands/a2o-worker.py
```

生成した worker は `runtime.phases.<phase>.executor.command` から参照する。

```yaml
command:
  - ./project-package/commands/a2o-worker.py
  - "--schema"
  - "{{schema_path}}"
  - "--result"
  - "{{result_path}}"
```

Custom worker を作る場合は、worker request と result の組を保存して次で検証する。

```sh
a2o worker validate-result --request request.json --result result.json
```

Validator は runtime 実行前に、missing key、type error、`task_ref` / `run_ref` / `phase` mismatch を具体的に出力する。Executor が configured review scope や repo-scope alias を使う場合は、同じ公開値を repeated `--review-scope SCOPE` と `--repo-scope-alias FROM=TO` で渡す。

## Verification And Remediation（検証と remediation）

Verification command は task result を証明する。Remediation command は verification retry の前に format や project-approved cleanup を行う。

良い verification command は deterministic で scope が明確である。

- 変更面を証明する最小 command を実行する。
- Failure diagnosis に必要な context を出力する。
- task が ready でなければ non-zero で終了する。
- 可能な限り hidden network や global machine dependency を避ける。

良い remediation command は保守的である。

- format や既知 artifact の再生成に限定する。
- product behavior を変更しない。
- commit、push、kanban state の編集をしない。

## Phase Skills（phase skill）

Skill は worker 向けの project-owned instruction である。Worker が安全に推測できない判断に絞って書く。

Implementation skill には次を書く。

- repository boundary と編集可能 path
- coding rule
- verification expectation
- project knowledge command を使う条件
- 記録すべき evidence

Review skill には次を書く。

- finding とみなす条件
- 期待する verification evidence
- public API、SPI、migration、documentation の確認観点
- residual risk の報告方法

Parent review skill には multi-repo integration の観点を書く。

- child output をどう統合するか
- live integration target はどの repo か
- merge readiness check
- merge 前に必要な evidence

Maintainer が実際に保守できる言語で書く。日本語で運用する project package なら、日本語の skill でよい。

## Knowledge Catalog（knowledge catalog）

A2O は knowledge catalog を必須にしない。また、特定 catalog 実装にも依存しない。

Project が catalog を持つ場合は、project-owned command または Taskfile entry として公開し、関連 skill に使い方を書く。Open-ended exploration ではなく、task-specific な限定 query を優先する。

Catalog は workflow stage ごとに使い分ける。

- Planning と task 分解では、比較的広い catalog query を使ってよい。関連する結果は kanban task に要約し、runtime worker が同じ context を再発見しなくてよい状態にする。
- Implementation worker には task-specific な query だけを渡す、または実行させる。Command 名、期待する query shape、使う理由を明示する。
- Review / parent review worker は、diff に関係する API/SPI surface、repository boundary、product rule、integration assumption の確認に catalog query を使う。
- MCP は必須にしない。Project-owned CLI、script、Taskfile query であっても、deterministic で package に文書化されていればよい。

Catalog result は補助情報として扱う。Source code、docs、tests、verification result が authoritative である。

## Review Checklist（レビュー観点）

実 task に使う前に確認する。

- `project.yaml` が唯一の公開 config file である。
- `a2o project lint --package ./project-package` に blocked finding がない。
- A2O-owned lane と internal label を package config に手書きしていない。
- `agent.required_bins` に product toolchain と worker executable が含まれている。
- Production phase が `tests/fixtures/` を呼んでいない。
- Verification command が明確に失敗し、diagnostics を出す。
- Remediation command が広範な予期しない変更を起こさない。
- Skill に repo boundary、review criteria、evidence expectation が書かれている。
- Generated files が `.work/a2o/` 配下に閉じている。
- 利用者向け docs と commands が A2O 名を使っている。
