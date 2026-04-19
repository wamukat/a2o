# Project Script Contract

A2O は project package が product 固有の automation を持つことを許容する。Package script は Ruby、Bash、Go、Python、Node、その他 project-local な選択でよい。安定させる境界は script の言語ではなく、A2O が提供する command、environment、request、result、workspace、evidence の contract である。

## 責務

A2O が所有するもの:

- phase lifecycle と許可される phase names
- kanban task selection と transitions
- workspace materialization と repo slot paths
- worker request/result transport
- evidence publication と merge orchestration
- diagnostic categories と remediation hints

Project package が所有するもの:

- product build、test、verification、remediation commands
- local dependency cache preparation など project 固有 bootstrap
- その product が必要とする support repo setup
- implementation / review で使う AI または deterministic executor command

Project scripts は `.a3/workspace.json`、`.a3/slot.json`、generated `launcher.json`、internal A3 environment names のような private runtime files に依存してはならない。

## Phase Command Contract

A2O は package command 用に次の public phases を定義する。

- `implementation`
- `review`
- `parent_review`
- `verification`
- `remediation`
- `merge`

Implementation、review、parent review は worker protocol 経由で実行する。Verification と remediation は materialized workspace 内の project command として実行する。Merge は policy で設定し、A2O が実行する。Project package はサポート済み merge behavior を選ぶだけで、新しい merge engine を実装しない。

Executor commands は次の placeholders を使える。

- `{{result_path}}`
- `{{schema_path}}`
- `{{workspace_root}}`
- `{{a2o_root_dir}}`
- `{{root_dir}}`

Verification and remediation commands は次を使える。

- `{{workspace_root}}`
- `{{a2o_root_dir}}`
- `{{root_dir}}`

## Worker Environment

Project worker、verification、remediation command は次の environment variables を使う。

- `A2O_WORKER_REQUEST_PATH`: current job の JSON request bundle。
- `A2O_WORKER_RESULT_PATH`: worker command が final JSON result を書き込む path。
- `A2O_WORKSPACE_ROOT`: current job の materialized workspace root。
- `A2O_ROOT_DIR`: worker から見える A2O runtime support files の root directory。
- `A2O_WORKER_LAUNCHER_CONFIG_PATH`: bundled stdin worker が使う generated launcher config。

`A3_*` names は compatibility aliases に限定する。Public project script contract ではない。

## Request Contract

Worker request JSON は project script にとっての source of truth である。含まれるもの:

- `task_ref`、`run_ref`、`phase`
- `skill`
- verification / remediation command job では `command_intent`
- `task_packet.title` と `task_packet.description`
- repo slot alias を key にした `slot_paths`
- task kind や必要に応じた verification commands を含む `phase_runtime`
- source descriptor と scope snapshot metadata

Scripts は workspace directory layout を推測せず、repo paths を `slot_paths` から読む。
Slot-local remediation では command の working directory が repo slot になる場合があるが、`A2O_WORKSPACE_ROOT` と `slot_paths` は full prepared workspace を指す。
Private `.a3` metadata を直接読まず、`A2O_WORKER_REQUEST_PATH` を使う。

## Result Contract

Worker commands は `A2O_WORKER_RESULT_PATH` に JSON object を 1 つ書く。Required keys は次の通り。

- `task_ref`
- `run_ref`
- `phase`
- `success`
- `summary`
- `failing_command`
- `observed_state`
- `rework_required`

Implementation success は repo slot ごとの `changed_files` も含める。Review と parent review は worker response schema に従って `review_disposition` を含められる。

## Cache And Artifacts

Task-local cache と artifact paths は A2O-managed workspace の責務である。Project package は materialized workspace 配下に product 固有 cache directories を作ってよいが、durable cache policy と evidence retention は A2O が所有する。新しい stable cache/artifact discovery helper が必要な場合は、script が private runtime paths に依存する前に A2O contract として追加する。

## Validation Direction

`a2o doctor`、`a2o project lint`、`a2o worker validate-result` は次を検出する。

- project package 内の `A3_*` worker environment names
- private `.a3` metadata files の直接読み取り
- required worker result keys の欠落
- public placeholders を使っていない executor commands
- undeclared binaries を必要とする verification/remediation commands

Lint output には次の修正手順を含める。例えば `A3_*` names は対応する `A2O_*` variables、`.a3` metadata reads は `A2O_WORKER_REQUEST_PATH` の `slot_paths`、`scope_snapshot`、`phase_runtime`、`launcher.json` references は `project.yaml` の phase executor settings へ誘導する。

目的は、project-specific automation を可能にしたまま、A2O release 間で安定した境界を維持することである。
