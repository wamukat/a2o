# Agent Worker Gateway Design（agent worker gateway 設計）

Agent worker gateway は、A2O Engine が project-local な作業を host または project dev-env で動く `a2o-agent` process へ委譲するための境界である。これにより、project toolchain を runtime image の外へ置いたまま、Engine-owned orchestration を維持できる。

## 目的

- Engine は task selection、phase transitions、workspace metadata、evidence、merge decisions を所有する。
- Agent は materialized workspace での project-local command execution を所有する。
- Project package は repo aliases、command profiles、required binaries、task template expectations を提供する。
- Gateway payloads は明示的な JSON contracts とし、場当たり的な shell argument bundles にしない。

## Flow（処理の流れ）

1. Engine が task phase 用の workspace を作成または更新する。
2. Engine が control plane 経由で agent job を publish する。
3. `a2o-agent` が job を pull し、要求された repo slots を materialize して、宣言された command を実行する。
4. Agent が structured result metadata と artifacts を upload する。
5. Engine が result を parse し、evidence を記録し、task を transition し、phase が許す場合は refs を publish または merge する。

## Workspace Metadata（workspace の metadata）

Agent jobs は次を含む。

- task ref and phase
- 該当する場合は parent/child relationship
- workspace id and branch namespace
- repo slot aliases
- source refs and support refs
- command profile and expected working directory
- artifact upload policy

Agent は global defaults から product-specific paths を推測してはならない。Paths は job payload と、その payload を作成した project package から渡される。

## Command Execution（command の実行）

Project commands は agent-side で実行する。Gateway は implementation workers、verification commands、merge commands、diagnostic commands を同じ control-plane shape で扱う。

Command runner は次を記録する。

- exit status
- stdout/stderr summary
- phase が edits を publish する場合の changed files
- declared evidence artifacts
- blocked tasks 用の structured failure reason

Verification commands は project package の責務である。Engine は success、failure、blocked reason、evidence metadata だけを解釈する。

## Worker Protocol Environment（worker protocol の環境変数）

Project package の command は、公開 contract として次の A2O 名を使う。

- `A2O_WORKER_REQUEST_PATH`: current job の JSON request bundle。
- `A2O_WORKER_RESULT_PATH`: command が final worker result JSON を書き込む path。
- `A2O_WORKSPACE_ROOT`: job の materialized workspace root。
- `A2O_WORKER_LAUNCHER_CONFIG_PATH`: bundled stdin worker が使う generated launcher config。

旧 `A3_*` 名は internal compatibility alias に限定する。Project package、template、user-facing diagnostics では使わない。

## Materialized Workspace Rules（materialized workspace の rules）

- Repo slot names は `app`、`repo_alpha`、`repo_beta` のような stable package aliases とする。
- 現 runtime が作成する user-visible branch refs は `refs/heads/a2o/...` を使う。既存の `refs/heads/a3/...` refs は legacy compatibility data である。
- Agent workspace paths は disposable であり、durable project configuration として使わない。
- Generated runtime metadata は product repo slot 内に置かず、`.work/a2o/agent/` 管理 path 配下へ閉じる。利用者が commit する source tree に A2O metadata を露出させない。

## Validation（検証）

Reference product suite は gateway を次の観点で検証する。

- TypeScript single-repo implementation / verification / merge
- Go single-repo implementation / verification / merge
- Python single-repo implementation / verification / merge
- Multi-repo parent-child implementation、child merge、parent review、parent verification、parent merge の flow

詳細は [90-reference-product-suite.md](90-reference-product-suite.md) を参照する。
