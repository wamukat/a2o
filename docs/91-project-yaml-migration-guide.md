# project.yaml Migration Guide

対象読者: A2O 利用者 / project package maintainer
文書種別: 移行手順

A2O の project package config は `project.yaml` に一本化された。以前の `manifest.yml` と `project.yaml` の 2 ファイル構成はサポート対象外である。

このガイドは、既存 package を single-file schema v1 へ移行するための手順を示す。

## 何が変わったか

以前の package は、project metadata と kanban / repo / agent 設定を `project.yaml` に置き、runtime presets、project surface、merge 設定を `manifest.yml` に置いていた。

現在は、すべて `project.yaml` に置く。

```text
project-package/
  README.md
  project.yaml
  kanban/bootstrap.json
  commands/
  skills/
  scenarios/
```

`manifest.yml` は削除する。残っている場合、A2O は package config を拒否する。

新規 package は `a2o project template` で最小構成を生成してから編集する。既存 package の移行時も、生成された短縮形の `runtime.executor.command` と `agent.required_bins` を比較対象にすると、手書きで不足しやすい項目を確認しやすい。

```sh
a2o project template \
  --package-name my-product \
  --kanban-project MyProduct \
  --language node \
  --executor-bin your-ai-worker \
  --output ./tmp-a2o-template/project.yaml
```

`--output` は `project.yaml` と `kanban/bootstrap.json` を生成する。既存ファイルは `--force` なしでは上書きしない。移行作業では既存 package に直接出力せず、別ディレクトリに生成して差分を比較する。

既存の full executor object はそのまま利用できる。新規または単純な package では、次の短縮形を使える。

```yaml
runtime:
  executor:
    command:
      - your-ai-worker
      - "--schema"
      - "{{schema_path}}"
      - "--result"
      - "{{result_path}}"
```

## 移行前

旧 `project.yaml`:

```yaml
project: a2o-reference-go-api-cli
kanban:
  provider: soloboard
  project: A2OReferenceGo
  bootstrap: kanban/bootstrap.json
repos:
  app:
    path: ..
    role: product
agent:
  workspace_root: .work/a2o-agent/workspaces
  required_bins:
    - git
    - go
runtime:
  kanban_status: To do
  live_ref: refs/heads/main
  max_steps: 20
  agent_attempts: 200
```

旧 `manifest.yml`:

```yaml
schema_version: "1"
presets:
  - base
core:
  merge_target: merge_to_live
  merge_policy: ff_only
  merge_target_ref: refs/heads/main
project:
  review_skill:
    default: skills/review/default.md
```

## 移行後

新 `project.yaml`:

```yaml
schema_version: 1
package:
  name: a2o-reference-go-api-cli
kanban:
  provider: soloboard
  project: A2OReferenceGo
  bootstrap: kanban/bootstrap.json
  selection:
    status: To do
repos:
  app:
    path: ..
    role: product
agent:
  workspace_root: .work/a2o-agent/workspaces
  required_bins:
    - git
    - go
    - your-ai-worker
runtime:
  live_ref: refs/heads/main
  max_steps: 20
  agent_attempts: 200
  executor:
    kind: command
    prompt_transport: stdin-bundle
    result:
      mode: file
    schema:
      mode: file
    default_profile:
      command:
        - your-ai-worker
        - "--schema"
        - "{{schema_path}}"
        - "--result"
        - "{{result_path}}"
      env: {}
    phase_profiles: {}
  presets:
    - base
  surface:
    implementation_skill: skills/implementation/base.md
    review_skill:
      default: skills/review/default.md
    verification_commands:
      - app/project-package/commands/verify.sh
    remediation_commands:
      - app/project-package/commands/format.sh
    workspace_hook: app/project-package/commands/bootstrap.sh
  merge:
    target: merge_to_live
    policy: ff_only
    target_ref: refs/heads/main
```

`runtime.surface` は package-local override である。旧 package で skill / command / hook が `presets/base.yml` などの preset file に定義されている場合、その preset file はそのまま使える。利用者がすぐに読めるように package の標準 skill / command / hook を `runtime.surface` へ明示してもよい。

## Field Mapping

| Old field | New field |
|---|---|
| `project` | `package.name` |
| `runtime.kanban_status` | `kanban.selection.status` |
| `manifest.yml.presets` | `runtime.presets` |
| `manifest.yml.core.merge_target` | `runtime.merge.target` |
| `manifest.yml.core.merge_policy` | `runtime.merge.policy` |
| `manifest.yml.core.merge_target_ref` | `runtime.merge.target_ref` |
| `manifest.yml.project.implementation_skill`, if present | `runtime.surface.implementation_skill` |
| `manifest.yml.project.review_skill`, if present | `runtime.surface.review_skill` |
| `manifest.yml.project.verification_commands`, if present | `runtime.surface.verification_commands` |
| `manifest.yml.project.remediation_commands`, if present | `runtime.surface.remediation_commands` |
| `manifest.yml.project.workspace_hook`, if present | `runtime.surface.workspace_hook` |

旧 `presets/*.yml` にある `implementation_skill`、`review_skill`、`verification_commands`、`remediation_commands`、`workspace_hook` は preset 定義であり、`runtime.presets` から参照される。移行時に必ず `runtime.surface` へ移す必要はない。

`schema_version: 1` は必須である。値は文字列でも数値でも読めるが、利用者向けの標準表記は数値の `1` とする。

## 手順

1. `project-package/project.yaml` を開く。
2. top-level `project` を `package.name` に移す。
3. `runtime.kanban_status` を `kanban.selection.status` に移す。
4. `manifest.yml` の `presets` を `runtime.presets` に移す。
5. `manifest.yml` の `core.merge_*` を `runtime.merge.*` に移す。
6. `manifest.yml.project` に project-specific な skill、verification、remediation、workspace hook override がある場合は `runtime.surface` に移す。`presets/*.yml` にある共通定義はそのまま残せる。
7. `schema_version: 1` を top-level に追加する。
8. `manifest.yml` を削除する。
9. reference product と同じ path 形式で command / skill / hook の参照先を確認する。

## Verification

移行後、package ごとに次を確認する。

```sh
ruby -ryaml -e 'YAML.safe_load(File.read(ARGV.fetch(0)), permitted_classes: [], aliases: false); puts "yaml=ok"' \
  project-package/project.yaml
```

host launcher 経由で確認する場合:

```sh
a2o project bootstrap --package ./project-package
a2o kanban doctor
a2o runtime doctor
```

runtime を実行する前に、`project.yaml`、`kanban/bootstrap.json`、`commands/`、`skills/` の path が package から見て正しいことを確認する。

## Checklist

- `project-package/manifest.yml` が存在しない。
- `project.yaml` の top-level に `schema_version: 1` がある。
- `package.name` がある。
- `kanban.project` と `kanban.selection.status` がある。
- `repos` に対象 repo slot がある。
- `agent.required_bins` に product toolchain と `runtime.executor` が使う binary がある。
- `runtime.presets` が配列である。
- `runtime.executor` がある。default worker を使う場合、executor は stdin bundle を受け取り `{{result_path}}` に worker result JSON を書く command として定義する。
- `runtime.presets` が参照する preset、または `runtime.surface` のどちらかで、実行可能な `verification_commands` を定義している。
- `runtime.merge.target`、`runtime.merge.policy`、`runtime.merge.target_ref` がある。
- 利用者が編集する schema に内部 coordination label を書いていない。

## Troubleshooting

`manifest.yml is no longer supported; use project.yaml`

`manifest.yml` が package に残っている、または runtime command に `manifest.yml` を渡している。`manifest.yml` の内容を `project.yaml` の `runtime.*` に移し、ファイルを削除する。

`project.yaml schema_version must be provided`

`schema_version: 1` がない。`project.yaml` の top-level に追加する。

`project.yaml runtime.presets must be provided`

旧 `manifest.yml.presets` を移していない。`runtime.presets` を配列で追加する。

`project.yaml runtime.merge.target and runtime.merge.policy must be provided`

旧 `manifest.yml.core.merge_target` と `manifest.yml.core.merge_policy` を移していない。`runtime.merge.target` と `runtime.merge.policy` を追加する。

`project package config ... is missing package.name`

旧 top-level `project` のままになっている。`package.name` に移す。

`project package config ... is missing kanban.project`

kanban board 名がない。`kanban.project` を設定する。

## Reference

現在の reference packages は移行済みである。自分の package に近いものを確認する。

- `reference-products/typescript-api-web/project-package/project.yaml`
- `reference-products/go-api-cli/project-package/project.yaml`
- `reference-products/python-service/project-package/project.yaml`
- `reference-products/multi-repo-fixture/project-package/project.yaml`
