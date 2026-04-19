# Single-File Project Package Schema（単一ファイル project package schema）

## 方針

Project package config の正規ファイル名は `project.yaml` とする。

`manifest.yml` は公開 0.5.0 package format に含めない。runtime の責務は `project.yaml` の明示的な runtime sections に置く。これにより、公開 package の command shape を小さく保ち、`a2o.yaml` のような別名を増やさず、package author にとって分かりにくい「project config」と「manifest」の分離をなくす。

Authoring 上の判断と責務境界は [50-project-package-authoring-guide.md](50-project-package-authoring-guide.md) を参照する。

Package schema は次の rules に従う。

- `project.yaml` を canonical file name とする。
- 新 schema では `manifest.yml` compatibility を要求しない。
- User-facing schema と diagnostics では A2O names を使う。A3 names は internal compatibility details としてだけ残してよい。
- `a2o:follow-up-child` のような internal follow-up labels は、通常の user-authored schema へ露出しない。

## Schema の形

```yaml
schema_version: 1

package:
  name: a2o-reference-typescript-api-web

kanban:
  project: A2OReferenceTypeScript
  selection:
    status: To do

repos:
  app:
    path: ..
    role: product
    label: repo:app

agent:
  workspace_root: .work/a2o/agent/workspaces
  required_bins:
    - git
    - node
    - npm
    - your-ai-worker

runtime:
  max_steps: 20
  agent_attempts: 200
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - your-ai-worker
          - "--schema"
          - "{{schema_path}}"
          - "--result"
          - "{{result_path}}"
    review:
      skill: skills/review/default.md
      executor:
        command:
          - your-ai-worker
          - "--schema"
          - "{{schema_path}}"
          - "--result"
          - "{{result_path}}"
    verification:
      commands:
        - app/project-package/commands/verify.sh
    remediation:
      commands:
        - app/project-package/commands/format.sh
    merge:
      target: merge_to_live
      policy: ff_only
      target_ref: refs/heads/main

task_templates:
  - path: task-templates/001-add-work-order-filter.md
```

Host agent binary は canonical path `.work/a2o/agent/bin/a2o-agent` に置く。導入時は `a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent` を使う。

## 各 section の責務

`schema_version` は必須である。Version `1` は最初の single-file schema を表す。未対応 version は、分かりやすい error で reject する。

`package` は product repository ではなく package を識別する。`package.name` は従来の top-level scalar `project` を置き換える。

`kanban` は board name、project-owned labels、task selection を持つ。kanban backend は A2O runtime distribution によって固定されており、author-facing な `project.yaml` setting ではない。A2O-owned lanes と internal coordination labels は runtime implementation details であり、通常の package schema に書かせない。

`repos` は stable repo slots を定義する。Slot keys は runtime identities である。`path` は absolute path でない限り package directory からの相対 path とする。`label` は kanban labels と repo slots を対応づける。省略時、implementation は `repo:<slot>` を derive してよい。

`agent` は host-side workspace、product toolchain requirements、executor command requirements を持つ。`required_bins` は、agent が作業開始前に prerequisites を validate できるよう declarative に残す。

`runtime` は execution defaults と phase definitions を持つ。

`runtime.phases` は phase-specific skills、executor commands、verification/remediation commands、merge policy を持つ。A2O は phase executor commands を internal stdin-bundle launcher config へ render する。利用者は別途 `launcher.json` を作らない。

Phase executor commands は worker bundle を stdin で受け取り、worker result JSON を `{{result_path}}` に書く必要がある。Executor command placeholders は `{{result_path}}`、`{{schema_path}}`、`{{workspace_root}}`、`{{a2o_root_dir}}`、`{{root_dir}}` を含む。Verification and remediation commands は `{{workspace_root}}`、`{{a2o_root_dir}}`、`{{root_dir}}` を support する。

Project commands は worker request JSON と `A2O_*` worker environment variables を stable contract として扱う。Package scripts から private `.a3` metadata files や generated `launcher.json` files を読んではならない。

通常の packages では implementation と review phases を定義する。

```yaml
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    review:
      skill: skills/review/default.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
```

これは内部的に fixed stdin-bundle command executor へ展開される。`prompt_transport`、`result`、`schema`、`default_profile` は A2O implementation details であり、valid な `project.yaml` fields ではない。

新しい package は executor block を手書きせず、generated template から始める。

```sh
a2o project template \
  --package-name my-product \
  --kanban-project MyProduct \
  --language node \
  --executor-bin your-ai-worker \
  --with-skills \
  --output ./project-package/project.yaml
```

Template は phase-based executor form を使う。`--language` は `agent.required_bins` を制御する。`--executor-bin` と repeated `--executor-arg` flags は implementation and review phase executor commands を生成する。

`--output` が file を指す場合、generator は `project.yaml` を書く。`--with-skills` を付けると、implementation、review、parent review の starter skill も書き、生成した parent skill を参照する `parent_review` phase を追加する。Kanban bootstrap data は `kanban.project`、`kanban.labels`、`repos.<slot>.label` から derive される。A2O-owned lanes と internal coordination labels は `a2o kanban up` が provision する。

`runtime.phases.merge` は merge target、policy、target ref を持つ。値は scalar または variant maps にでき、current merge resolver behavior と一致する。

`task_templates` は validation と onboarding のための optional metadata である。Task template entry は markdown task template を指す。Runtime task selection は引き続き kanban から行う。Task templates は default では auto-enqueue されない。

## Reference Product の例

### TypeScript API/Web

```yaml
schema_version: 1
package:
  name: a2o-reference-typescript-api-web
kanban:
  project: A2OReferenceTypeScript
  selection:
    status: To do
repos:
  app:
    path: ..
    label: repo:app
    role: product
agent:
  required_bins: [git, node, npm, your-ai-worker]
runtime:
  max_steps: 20
  agent_attempts: 200
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    review:
      skill: skills/review/default.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    verification:
      commands:
        - app/project-package/commands/verify.sh
    remediation:
      commands:
        - app/project-package/commands/format.sh
    merge:
      target: merge_to_live
      policy: ff_only
      target_ref: refs/heads/main
```

### Go API/CLI

```yaml
schema_version: 1
package:
  name: a2o-reference-go-api-cli
kanban:
  project: A2OReferenceGo
  selection:
    status: To do
repos:
  app:
    path: ..
    label: repo:app
agent:
  required_bins: [git, go, your-ai-worker]
runtime:
  max_steps: 20
  agent_attempts: 200
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    review:
      skill: skills/review/default.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    verification:
      commands:
        - app/project-package/commands/verify.sh
    merge:
      target: merge_to_live
      policy: ff_only
      target_ref: refs/heads/main
```

### Python Service

```yaml
schema_version: 1
package:
  name: a2o-reference-python-service
kanban:
  project: A2OReferencePython
  selection:
    status: To do
repos:
  app:
    path: ..
    label: repo:app
agent:
  required_bins: [git, python3, your-ai-worker]
runtime:
  max_steps: 20
  agent_attempts: 200
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    review:
      skill: skills/review/default.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    verification:
      commands:
        - app/project-package/commands/verify.sh
    merge:
      target: merge_to_live
      policy: ff_only
      target_ref: refs/heads/main
```

### Multi-Repo Fixture

```yaml
schema_version: 1
package:
  name: a2o-reference-multi-repo
kanban:
  project: A2OReferenceMultiRepo
  labels:
    - repo:both
  selection:
    status: To do
repos:
  repo_alpha:
    path: ../repos/catalog-service
    role: product
    label: repo:catalog
  repo_beta:
    path: ../repos/storefront
    role: product
    label: repo:storefront
agent:
  required_bins: [git, node, your-ai-worker]
runtime:
  max_steps: 40
  agent_attempts: 300
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    review:
      skill: skills/review/default.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    parent_review:
      skill: skills/review/parent.md
      executor:
        command: [your-ai-worker, --schema, "{{schema_path}}", --result, "{{result_path}}"]
    verification:
      commands:
        - "{{a2o_root_dir}}/reference-products/multi-repo-fixture/project-package/commands/verify-all.sh"
    remediation:
      commands:
        - "{{a2o_root_dir}}/reference-products/multi-repo-fixture/project-package/commands/format.sh"
    merge:
      target:
        default: merge_to_live
        variants:
          task_kind:
            child:
              default: merge_to_parent
            parent:
              default: merge_to_live
      policy: ff_only
      target_ref:
        default: refs/heads/main
```

## 現在の状態

1. Single loader が `project.yaml` schema version `1` を読む。
2. Runtime bridge は `runtime.phases` から internal runtime package data を derive する。
3. Reference product packages には `manifest.yml` を含めない。
4. 4 つの reference packages は single-file `project.yaml` を使う。
5. User docs と reference package docs は、author に `manifest.yml` 作成を求めない。
6. Package loading は old split files を reject する。
7. Package schema、docs、normal diagnostics は A2O-facing names を使う。

## 実装 notes

- New loader は `manifest.yml` を必要とする packages を reject する。
- Schema は A2O-facing fields を current internal Ruby runtime structures へ translate してよい。ただし errors と docs は、users に A3 names を author するよう求めてはならない。
- Internal follow-up labels は runtime defaults を持つべきである。Advanced overrides は、実 product が必要とした場合だけ追加する。
