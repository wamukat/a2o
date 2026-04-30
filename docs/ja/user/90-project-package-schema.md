# プロジェクトパッケージスキーマのリファレンス

この文書は `project.yaml` の詳細リファレンスである。導入時の考え方は先に [20-project-package.md](20-project-package.md) を読む。

この文書は、設定値を追加・変更するときに参照する。先に [20-project-package.md](20-project-package.md) で「なぜその設定が必要か」を理解し、この文書では実際の YAML 形、既定の責務境界、使えるプレースホルダーを確認する。

## 方針

プロジェクトパッケージ設定の正規ファイル名は `project.yaml` とする。

ランタイムの責務は `project.yaml` の明示的なランタイムセクションに置く。公開パッケージの設定ファイルは 1 本にまとめ、パッケージ作成者がプロジェクト設定とランタイム定義の責務分担で迷わない形にする。

作成時の判断と責務境界は [20-project-package.md](20-project-package.md) を参照する。

パッケージスキーマは次のルールに従う。

- `project.yaml` を正規ファイル名とする。
- 公開パッケージ設定は `project.yaml` だけを使う。
- 利用者向けのスキーマと診断では A2O 名を使う。A3 名は内部互換の詳細としてだけ残してよい。
- `a2o:follow-up-child` のような内部 follow-up ラベルは、通常の利用者作成スキーマへ露出しない。

## スキーマの形

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

docs:
  repoSlot: app
  root: docs
  index: docs/README.md
  categories:
    architecture:
      path: docs/architecture
      index: docs/architecture/README.md
  languages:
    primary: ja
  impactPolicy:
    defaultSeverity: warning
    mirrorPolicy: require_canonical_warn_mirror
  authorities:
    openapi:
      source: openapi.yaml
      docs:
        - docs/api.md

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
  agent_poll_interval: 1s
  agent_control_plane_connect_timeout: 5s
  agent_control_plane_request_timeout: 30s
  agent_control_plane_retry_count: 2
  agent_control_plane_retry_delay: 1s
  review_gate:
    child: false
    single: false
    skip_labels: []
    require_labels: []
  decomposition:
    investigate:
      command: [app/project-package/commands/investigate.sh]
    author:
      command: [app/project-package/commands/author-proposal.sh]
    review:
      commands:
        - [app/project-package/commands/review-proposal-architecture.sh]
        - [app/project-package/commands/review-proposal-planning.sh]
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
      policy: ff_only
      target_ref: refs/heads/main

task_templates:
  - path: task-templates/001-add-work-order-filter.md
```

ホスト側のエージェントバイナリは正規パス `.work/a2o/agent/bin/a2o-agent` に置く。導入時は `a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent` を使う。

## 各セクションの責務

`schema_version` は必須である。Version `1` は最初の単一ファイルスキーマを表す。未対応 version は、分かりやすいエラーで拒否する。

`package` はプロダクトのリポジトリではなく、パッケージを識別する。`package.name` は安定したパッケージ識別子であり、ファイルシステムとブランチ参照で安全に使える名前にする。

`runtime.agent_attempts` と `runtime.agent_poll_interval` は host agent の外側ループを制御する。

`runtime.agent_control_plane_connect_timeout`、`runtime.agent_control_plane_request_timeout`、`runtime.agent_control_plane_retry_count`、`runtime.agent_control_plane_retry_delay` は、host agent が local agent server へ HTTP 接続するときの connect timeout / request timeout / retry を制御する。TCP 接続 timeout や一時的な control-plane failure を project ごとに調整したいときはここを使う。

`runtime.review_gate.child` と `runtime.review_gate.single` は任意の boolean であり、既定は `false` である。有効にした task kind は implementation 成功後に verification へ直行せず、先に `review` へ遷移する。レビュー承認後は verification へ進み、レビュー指摘がある場合は implementation へ戻せる。

`runtime.review_gate.skip_labels` と `runtime.review_gate.require_labels` は任意のカンバンラベル名配列である。`require_labels` は task kind の既定値が `false` でも一致タスクの review gate を有効にする。`skip_labels` は task kind の既定値が `true` でも一致タスクの review gate を無効にする。両方に一致した場合は `skip_labels` を優先する。

`kanban` はボード名、プロジェクトが所有するラベル、タスク選択条件を持つ。カンバンの接続先は `a2o project bootstrap` で作るランタイムインスタンス側の設定であり、作成者向けの `project.yaml` 設定ではない。A2O が管理するレーンと内部調整ラベルはランタイム実装の詳細であり、通常のパッケージスキーマには書かせない。

複数リポジトリの親タスクには、対象リポジトリラベルをすべて付ける。「全リポジトリ」や「両方」を意味する合成ラベルは作らない。合成ラベルは 2 リポジトリを超える構成に拡張できず、リポジトリスロットと直接対応しない。

`repos` は安定したリポジトリスロットを定義する。スロットキーはランタイム上の識別子である。`path` は絶対パスでない限り、パッケージディレクトリからの相対パスとする。`label` はカンバンラベルとリポジトリスロットを対応づける。省略時、実装処理は `repo:<slot>` を導出してよい。

`docs` は任意である。タスクに docs-impact がある場合に、A2O が参照または更新してよいドキュメント面を宣言する。単一 repo package では `docs.repoSlot` を省略でき、その repo slot に docs path が属するとみなす。multi-repo package、または docs が専用 repository にある場合は、その repository を `repos` に宣言し、対応する slot を `docs.repoSlot` に設定する。

```yaml
docs:
  repoSlot: docs
  root: docs
  index: docs/README.md
  categories:
    architecture:
      path: docs/architecture
      index: docs/architecture/README.md
    shared_specs:
      path: docs/shared-specs
  languages:
    primary: ja
    secondary: [en]
  policy:
    missingRoot: create
  impactPolicy:
    defaultSeverity: warning
    mirrorPolicy: require_canonical_warn_mirror
  authorities:
    openapi:
      source: openapi.yaml
      docs:
        - docs/api.md
```

`docs.root`、`docs.index`、category path、authority source、authority docs は repo slot からの相対 path である。A2O は absolute path、`..` による escape、選択した repo slot の外へ解決される既存 symlink を拒否する。`docs.repoSlot` は `repos` に宣言された slot と一致しなければならない。category id と authority id は `architecture`、`shared_specs`、`openapi` のような空でない machine-readable key にする。

`docs.impactPolicy.mirrorPolicy` は `docs.languages.secondary` に対する mirror debt の扱いを制御する。`require_all` は宣言されたすべての言語を同じ変更で更新する方針、`require_canonical_warn_mirror` は不足した secondary docs を mirror debt として記録する方針、`canonical_only` は mirror debt を記録しない方針である。

authority source は OpenAPI、DB migration、生成 schema、既存の shared specification などの source of truth artifact を表す。repo slot checkout が利用できる場合、generated ではない authority source は存在していなければならない。`generated: true` は、project policy としてその source が現在の checkout 外で生成されることを意図的に認める場合だけ使う。

### docs-impact の流れ

`docs` を設定すると、A2O は implementation、review、parent-review、decomposition の worker request に `docs_context` を含める。ここには、設定済み category、候補 docs、authority source、言語ポリシー、期待する docs action、traceability refs が入る。実際に docs-impact があるかは task ごとに worker が判断し、`docs_impact` evidence として返す。

implementation result には次のような値を含められる。

```json
{
  "docs_impact": {
    "disposition": "yes",
    "categories": ["shared_specs", "interfaces"],
    "updated_docs": [
      "docs/shared-specs/greeting-format.md",
      "docs/interfaces/greeting-api.md"
    ],
    "updated_authorities": ["greeting_api"],
    "skipped_docs": [
      {
        "path": "docs/ja/interfaces/greeting-api.md",
        "reason": "mirror follow-up"
      }
    ],
    "matched_rules": ["interface_changed"],
    "review_disposition": "accepted",
    "traceability": {
      "related_requirements": ["A2O#394"],
      "source_issues": ["wamukat/a2o#16"],
      "related_tickets": ["A2O#391", "A2O#393"]
    }
  }
}
```

review phase は同じ evidence を確認する。`disposition: yes` または `maybe` の場合、review は `review_disposition` として `accepted`、`warned`、`blocked`、`follow_up` のいずれかを返す。child review の `blocked` は implementation へ戻す。parent-review の `follow_up` は follow-up child を作る、または紐づける必要があり、docs debt を成功結果の裏に隠してはならない。

Kanban コメントには短い docs-impact summary だけを残す。現在レーン、run status、review disposition、merge status のような lifecycle state は run evidence とタスクコメントが持つ。docs front matter へこれらをコピーしない。

既存プロジェクトは `docs` を省略したまま動かせる。段階的に移行する場合は、まず `docs.root`、1 つの category、1 つの managed index block を追加し、その後で authority と言語ポリシーを足す。A2O は危険な docs path を明示的な validation error で拒否するため、runtime 処理を有効にする前に package validation を通す。

`agent` はホスト側ワークスペース、プロダクトのツールチェーン要件、実行コマンド要件を持つ。`required_bins` は、エージェントが作業開始前に前提条件を検証できるよう宣言的に残す。

`runtime` は実行時の既定値とフェーズ定義を持つ。

## Runtime Decomposition

`runtime.decomposition.investigate.command` は、`trigger:investigate` チケット分解で使うプロジェクト所有の調査コマンドである。`runtime.decomposition.author.command` は、調査証跡を正規化された child-ticket proposal に変換するプロジェクト所有コマンドである。プロジェクトが該当する decomposition pipeline step を使う場合に指定する。

各コマンドは空でない文字列配列でなければならない。

```yaml
runtime:
  decomposition:
    investigate:
      command:
        - app/project-package/commands/investigate.sh
        - "--format"
        - json
    author:
      command:
        - app/project-package/commands/author-proposal.sh
        - "--format"
        - json
    review:
      commands:
        - [app/project-package/commands/review-proposal-architecture.sh]
        - [app/project-package/commands/review-proposal-planning.sh]
```

A2O は隔離された disposable decomposition workspace で decomposition command を実行する。investigation command には次の公開 `A2O_*` パスを渡す。

- `A2O_DECOMPOSITION_REQUEST_PATH`
- `A2O_DECOMPOSITION_RESULT_PATH`
- `A2O_WORKSPACE_ROOT`

request JSON には、source task の `title`、`description`、label、priority、parent / child / blocker ref、隔離された repo `slot_paths`、`source_task`、過去の investigation evidence が存在する場合の rerun context である `previous_evidence_path` と `previous_evidence_summary` が含まれる。A2O は investigation 実行前に、source task title と description が空でないことを要求する。

コマンドは `A2O_DECOMPOSITION_RESULT_PATH` に単一の JSON object を書く。MVP では `summary` を空でない文字列として必須にする。非ゼロ終了、JSON 未作成、不正 JSON、`summary` 欠落は、証跡付きで decomposition run を block する。

investigation を実行するには次を使う。

```bash
a2o runtime decomposition investigate A2O#123 --repo-source repo_alpha=/path/to/repo
```

author command には次を渡す。

- `A2O_DECOMPOSITION_AUTHOR_REQUEST_PATH`
- `A2O_DECOMPOSITION_AUTHOR_RESULT_PATH`
- `A2O_WORKSPACE_ROOT`

author command は `A2O_DECOMPOSITION_AUTHOR_RESULT_PATH` に proposal JSON object を 1 つ書く。A2O は draft を正規化し、`proposal_fingerprint` と child ごとの `child_key` を導出し、Kanban child ticket は作成せずに proposal evidence を保存する。proposal には 1 件以上の child draft が必要である。各 child draft は `title`、`body`、`acceptance_criteria`、`labels`、`depends_on`、`boundary`、`rationale` を持つ。`boundary` は child idempotency key の導出元になるため rerun 間で安定している必要がある。`unresolved_questions` は配列でなければならない。

investigation evidence が存在する状態で proposal step を実行するには次を使う。

```bash
a2o runtime decomposition propose A2O#123
```

既定では storage directory 配下の `decomposition-evidence/<task>/investigation.json` を読む。別の evidence file を使う場合は `--investigation-evidence-path` を指定する。task が外部 Kanban ticket と紐づいている場合、A2O は proposal summary を source ticket に投稿する。

proposal review command は逐次実行する。各 command には次を渡す。

- `A2O_DECOMPOSITION_REVIEW_REQUEST_PATH`
- `A2O_DECOMPOSITION_REVIEW_RESULT_PATH`
- `A2O_WORKSPACE_ROOT`

各 review result は `summary` と `findings` を持つ JSON object とする。finding の `severity` は `critical`、`major`、`minor`、`info` を使う。`critical` finding が 1 件でもあれば proposal は block され、証跡が保存される。clean review は proposal を次の configured gate に進められる `eligible` として扱うが、child ticket は作成しない。

```bash
a2o runtime decomposition review A2O#123
a2o runtime decomposition status A2O#123
```

child ticket creation は明示 gate の後ろに置き、Kanban command boundary を必須にする。

```bash
a2o runtime decomposition create-children A2O#123 --gate
```

このコマンドは `--gate` がない場合は child を作成せず、eligible proposal を `blocked` に変えずに `gate_closed` evidence を記録する。同じ proposal fingerprint に対する eligible proposal review が必要であり、既存 child は child key で再利用する。Kanban-first draft mode では、作成または再利用された child は draft の計画 artifact のままである。A2O は `a2o:draft-child` を付け、`trigger:auto-implement` や `trigger:auto-parent` は付けない。child が実装スケジューラに入るのは、運用者が承認として `trigger:auto-implement` を付けた後である。

trial cleanup は既定で dry-run になる。

```bash
a2o runtime decomposition cleanup A2O#123 --dry-run
a2o runtime decomposition cleanup A2O#123 --apply
```

cleanup は task slug に対応する local evidence と disposable workspace の path を表示し、evidence から proposal fingerprint と child ref を読み取って表示する。`--apply` は選択した task の `decomposition-evidence/<task>` と `decomposition-workspaces/<task>` だけを削除する。Kanban ticket や comment はこの command では削除しない。

host launcher wrapper は、bootstrap 済み runtime package から storage、project config、Kanban、repo label、既定の repo source 設定を読む。package 内に通常とは異なる config file がある場合は `--project-config project-test.yaml` を使う。低レベルの runtime-container command は診断用に残すが、利用者向けの運用では `a2o runtime decomposition ...` wrapper を優先する。

## Runtime Prompts

`runtime.prompts` は任意設定である。省略した場合、A2O は既存の phase skill 動作を維持する。既存の phase skill から移行する場合は [Runtime Prompt Migration](#runtime-prompt-migration) を参照する。

この section は provider に依存しない project prompt 入力を定義する。これらのファイルは project 固有の追加ガイダンスであり、A2O core の safety rule、worker result schema、workspace boundary、runtime control rule を上書きしない。

```yaml
runtime:
  prompts:
    system:
      file: prompts/system.md
    phases:
      implementation:
        prompt: prompts/implementation.md
        skills:
          - skills/testing-policy.md
      implementation_rework:
        prompt: prompts/implementation-rework.md
      review:
        prompt: prompts/review.md
      parent_review:
        prompt: prompts/parent-review.md
      decomposition:
        prompt: prompts/decomposition.md
        childDraftTemplate: prompts/decomposition-child-template.md
    repoSlots:
      app:
        phases:
          review:
            skills:
              - skills/app-review.md
```

すべての path は package からの相対 path で、空文字は使えない。prompt phase 名は A2O が認識する phase profile に限定される。`phases.<phase>.skills` は宣言順を維持し、同じ skill file を重複指定してはならない。`implementation_rework` は任意であり、未設定の場合は `implementation` の prompt profile にフォールバックする。`repoSlots.<slot>.phases` は project phase default に対する追加 layer であり、`<slot>` は `repos` の entry と一致する必要がある。phase prompt / skill の後に repo-slot prompt / skill を合成し、diagnostics/evidence では `repo_slot_phase_prompt`、`repo_slot_phase_skill`、`repo_slot_decomposition_child_draft_template` として区別できる。

複数 repo をまたぐ task では、A2O は task の `repo_slots` / `edit_scope` に含まれる各 slot の repo-slot addon を、その順序で合成する。たとえば `app` と `lib` を触る multi-repo implementation では、project-wide phase prompt の後に `repoSlots.app` の phase addon、続いて `repoSlots.lib` の phase addon、最後に ticket-specific instruction を渡す。diagnostics には順序付き list として `repo_slots` を出す。`repo_scope` は互換 field として残し、従来の単数 `repo_slot` は single-slot task の場合だけ設定する。複数 slot の指示を同時に渡すと広すぎる、または衝突する場合は、task を repo slot 単位の child に分ける。

合成順序は固定で、すべて追加 layer として扱う。

```text
A2O core worker contract
  > runtime.prompts.system
  > runtime.prompts.phases.<profile>.prompt
  > runtime.prompts.phases.<profile>.skills
  > runtime.prompts.repoSlots.<slot>.phases.<profile> addons for each scoped slot
  > ticket-specific instruction and task packet
```

project prompt では、言語、tone、local convention、review stance、decomposition policy、phase ごとの再利用可能な作業指針を定義できる。一方で、必須 worker result schema、workspace boundary、branch / publish safety、Kanban gate、review requirement、runtime state transition は無効化できない。project prompt と A2O runtime rule が衝突した場合は runtime rule が優先される。

典型的な prompt file は短い Markdown として用意する。

```markdown
<!-- prompts/system.md -->
日本語で応答する。利用者向けコメントは簡潔にする。既存のプロジェクト規約を守り、無関係なリファクタリングは避ける。

<!-- prompts/implementation.md -->
チケットを満たす最小の一貫した変更を実装する。まず focused test を実行し、共有動作に触れる場合は広めの検証も行う。変更ファイルと検証結果を報告する。

<!-- prompts/review.md -->
regression、acceptance coverage の不足、missing tests、危険な互換性変更を確認する。finding には file / line reference を含める。

<!-- prompts/parent-review.md -->
child の成果物が統合可能かを判断する。parent 完了前に必須の作業だけを follow-up child として指摘する。

<!-- prompts/decomposition.md -->
大きな要求を、明確な ownership、dependencies、non-goals、acceptance criteria、verification method を持つ draft child ticket に分割する。
```

skill は phase から参照する長めの再利用可能 Markdown guidance である。phase stance や instruction layering は prompt に置き、testing policy、API compatibility rule、UI review checklist、Kanban decomposition template などの詳細手順は skill に置く。`childDraftTemplate` は decomposition 専用で、期待する child ticket 形状を proposal author request に渡す。永続 evidence には raw content ではなく安全な prompt metadata だけを保存する。

worker を実行する前に prompt composition を確認するには次を使う。

```bash
a2o prompt preview --phase review A2O#123
a2o prompt preview --phase decomposition --repo-slot app A2O#123
a2o prompt preview --phase decomposition --repo-slot app --repo-slot lib A2O#123
```

preview は Kanban state を変更せず、選択した phase に適用される A2O core instruction、project system prompt、phase prompt、phase skill、repo-slot addon、ticket phase instruction、task/runtime data、最終的な composed instruction を layer ごとに表示する。multi-repo 合成を確認する場合は、task の `repo_slots` / `edit_scope` と同じ順序で `--repo-slot` を複数指定する。`parent_review` を見る場合は `--task-kind parent`、`implementation_rework` を見る場合は `--prior-review-feedback` を指定する。

worker を実行せず、Kanban state も変更せずに prompt config を診断するには次を使う。

```bash
a2o doctor prompts
```

prompt doctor は、missing file、invalid path、unsupported prompt phase、duplicate skill entry、invalid repo-slot addon、fallback を含む prompt profile、`childDraftTemplate` の不正配置を、package path と phase context つきで報告する。

コピーして使える baseline として `samples/prompt-packs/ja-conservative/` を用意している。日本語 system prompt、implementation、implementation rework、review、parent review、decomposition の phase prompt、再利用可能な phase skill、decomposition child draft template、最小の `runtime.prompts` config snippet を含む。

## Prompt Authoring Boundaries

instruction は、意図に合う最も狭く永続的な surface に置く。

- Project system prompt: すべての phase に適用する言語、tone、安定した project-wide rule、compatibility posture、general policy。
- Phase prompt: implementation scope、implementation rework stance、review disposition、parent-review integration policy、decomposition strategy など、phase ごとに変わる短い behavior guidance。
- Phase skill: testing policy、technology-specific operating note、migration guide、domain checklist、review rubric、decomposition rule など、長めの再利用可能手順。
- Ticket-specific instruction: その ticket 固有の acceptance criteria、一回限りの制約、一時的な例外、人間の判断、priority、必要な evidence。

project prompt / skill は durable な内容に限る。1 ticket だけに必要な指示は ticket に置く。多くの ticket にまたがって 1 phase だけへ適用する指示は phase prompt または phase skill に置く。すべての phase に適用し、task ごとに変わりにくい指示だけを system prompt に置く。

よくない配置は次の通り。

- 一回限りの ticket requirement を `prompts/system.md` に入れ、将来の無関係な task に古い制約を継承させる。
- 同じ長い checklist を各 phase prompt に重複して書き、phase skill として再利用しない。
- schema override、workspace escape、branch bypass、Kanban mutation、review skip の指示を project prompt file に入れる。A2O core contract は上書きできない。
- 人間の承認が必要な product decision を再利用可能 skill に入れる。その判断は ticket または明示的な project documentation に置く。
- version 管理すべき安定した project policy を ticket comment にだけ残す。

優先順位は additive である。A2O core worker contract と phase skill が先にあり、`runtime.prompts.system`、phase prompt、phase skill、repo-slot addon、最後に ticket-specific instruction が続く。`implementation_rework` は rework-specific prompt profile がなければ `implementation` にフォールバックし、parent review run では `parent_review` が選択される。既存 project package からの移行は [Runtime Prompt Migration](#runtime-prompt-migration) を参照する。コピー可能な baseline は `samples/prompt-packs/ja-conservative/` を参照する。

## Runtime Prompt Migration

既存の project package は、新しい A2O version を使う前に必ず移行する必要はない。現在リリース済みの phase execution surface は引き続きサポートされる。

- `runtime.phases.implementation.skill`
- `runtime.phases.review.skill`
- project が parent review を使う場合の `runtime.phases.parent_review.skill`
- `runtime.phases` 配下の phase executor、verification、remediation、merge command
- `runtime.decomposition` 配下の decomposition command 設定

新しい `runtime.prompts` surface は追加 guidance である。phase skill や executor contract を置き換えるものではない。まず既存 phase skill を維持したまま project-specific guidance を prompt file に移し、新しい prompt layering を検証した後にだけ古い skill file を整理する。

移行前の project では、多くの guidance が phase skill に入っている。

```yaml
runtime:
  phases:
    implementation:
      skill: skills/implementation.md
      executor:
        command: [project-package/commands/implementation.sh]
    review:
      skill: skills/review.md
      executor:
        command: [project-package/commands/review.sh]
    parent_review:
      skill: skills/parent-review.md
      executor:
        command: [project-package/commands/parent-review.sh]
  decomposition:
    author:
      command: [project-package/commands/decompose.sh]
```

移行後も phase skill は runtime worker contract として残し、project policy、phase stance、再利用可能 checklist、rework behavior、decomposition ticket shape を project prompt layer として追加する。

```yaml
runtime:
  prompts:
    system:
      file: prompts/system.md
    phases:
      implementation:
        prompt: prompts/implementation.md
        skills:
          - skills/testing-policy.md
      implementation_rework:
        prompt: prompts/implementation-rework.md
      review:
        prompt: prompts/review.md
        skills:
          - skills/review-checklist.md
      parent_review:
        prompt: prompts/parent-review.md
      decomposition:
        prompt: prompts/decomposition.md
        childDraftTemplate: prompts/decomposition-child-template.md
  phases:
    implementation:
      skill: skills/implementation.md
      executor:
        command: [project-package/commands/implementation.sh]
    review:
      skill: skills/review.md
      executor:
        command: [project-package/commands/review.sh]
    parent_review:
      skill: skills/parent-review.md
      executor:
        command: [project-package/commands/parent-review.sh]
  decomposition:
    author:
      command: [project-package/commands/decompose.sh]
```

既存内容を移すときは次の分担にする。

- Project system prompt: 言語、tone、product-wide convention、compatibility posture、repository ownership rule。
- Phase prompt: implementation scope、rework handling、review disposition、parent integration review、decomposition strategy など、その phase の goal と decision policy。
- `runtime.prompts.phases.<phase>.skills` 配下の phase skill file: 長めの再利用可能手順、checklist、testing policy、API compatibility rule、review heuristic。
- Ticket-specific instruction: その ticket 固有の acceptance criteria、要求動作、priority、制約、必要な evidence。

優先順位は固定である。`runtime.phases.<phase>.skill` を設定している場合、その従来の phase skill は `a2o_core_instruction` layer として最初に出力され、worker result schema、process boundary、required output に対する正本であり続ける。`runtime.prompts` layer は、その contract の後、ticket-specific instruction の前に追加される。古い phase skill と新しい prompt config が両方ある場合、project prompt は context を追加できるが、A2O runtime rule、workspace boundary、Kanban gate、result schema は上書きできない。

phase guidance を `runtime.prompts.phases.<phase>` へ完全に移した project では、その phase の `runtime.phases.<phase>.skill` を省略できる。この prompts-only mode では、省略した skill に対する `a2o_core_instruction` layer は出力されない。project system prompt、phase prompt、phase skill file、repo-slot addon、ticket-specific instruction が project prompt stack を構成する。対応する prompt phase には、少なくとも prompt または skill file のどちらかが必要である。system prompt だけでは、その phase が prompts-backed とはみなされない。

`implementation_rework` は prompt profile であり、独立した scheduler phase ではない。prior review feedback を含む implementation request で選択され、省略時は `implementation` にフォールバックする。`parent_review` は他の review profile と同じ prompt layering を使う。`decomposition` は decomposition prompt と任意の `childDraftTemplate` を使う。template は decomposition 専用であり、期待する draft child ticket format を記述する。

A2O は、prompt migration の不正を `a2o project validate` と `a2o project lint` の diagnostics として報告する。典型的な失敗は、prompt / skill file の欠落、package root 外の path、file ではない path、unsupported prompt phase name、同一 phase layer 内の duplicate skill file、未知の `repoSlots` key、repo-slot skill addition の重複、`decomposition` 以外の `childDraftTemplate` である。validation coverage には、`runtime.prompts` を持たない old-style package と project prompt config を持つ new-style package の両方が含まれる。

これは coexistence policy であり、deprecation notice ではない。既存の phase skill は、将来の release で deliberate migration/removal plan が文書化されるまで動作し続ける。一方で、phase guidance を意図的に `runtime.prompts` へ移した project では prompts-only phase も利用できる。

## Runtime Phases

`runtime.phases` はフェーズごとのスキル、実行コマンド、検証 / 修復コマンド、マージ方針を持つ。A2O はフェーズごとの実行コマンドを内部の標準入力バンドル用ランチャー設定へ変換する。利用者は別途 `launcher.json` を作らない。`runtime.phases.<phase>.skill` は package skill file を指す。implementation / review phase では、対応する `runtime.prompts.phases.<phase>` に prompt または skill content がある場合だけ、この skill を省略できる。phase skill も対応する prompt phase もない場合、validation は `runtime.phases.<phase>.skill must be provided` 診断で失敗する。

フェーズ実行コマンドはワーカーバンドルを標準入力で受け取り、ワーカー結果 JSON を `{{result_path}}` に書く必要がある。実行コマンド用プレースホルダーには `{{result_path}}`、`{{schema_path}}`、`{{workspace_root}}`、`{{a2o_root_dir}}`、`{{root_dir}}` が含まれる。検証コマンドと修復コマンドは `{{workspace_root}}`、`{{a2o_root_dir}}`、`{{root_dir}}` を使える。

プロジェクトコマンドは、ワーカー要求 JSON と `A2O_*` ワーカー環境変数を安定した契約として扱う。パッケージスクリプトから非公開の `.a2o/.a3` メタデータファイルや生成された `launcher.json` ファイルを読んではならない。
実装、レビュー、検証、修復のジョブはすべて `A2O_WORKER_REQUEST_PATH` を公開する。検証と修復の要求 JSON は `command_intent`、`slot_paths`、`scope_snapshot`、`phase_runtime` を含むため、対象リポジトリスロットや適用方針はこれらから判断する。
スロット単位の修復では、コマンドのカレントディレクトリがリポジトリスロットになる場合があるが、要求は準備済みワークスペース全体を表す。

検証コマンドと修復コマンドは、マージ設定と同じ `default` / `variants` 形式も使える。`task_kind`、`repo_scope`、フェーズによってコマンド方針が変わる場合だけ使う。

```yaml
runtime:
  phases:
    verification:
      commands:
        default:
          - app/project-package/commands/verify-all.sh
        variants:
          task_kind:
            parent:
              phase:
                verification:
                  - app/project-package/commands/verify-parent.sh
    remediation:
      commands:
        default:
          - app/project-package/commands/format-all.sh
        variants:
          task_kind:
            child:
              repo_scope:
                repo_beta:
                  phase:
                    verification:
                      - app/project-package/commands/format-repo-beta.sh
```

単純なリスト形式を既定とする。ヘルパーコードにタスク種別やリポジトリスロット方針が隠れてしまう場合だけ variants を使う。
`default` はトップレベル、`task_kind` 配下、`repo_scope` 配下に指定できる。より具体的に一致した値が優先される。

### メトリクス収集

`runtime.phases.metrics.commands` は任意設定である。指定した場合、A2O は検証が成功した後にだけこれらのコマンドを実行する。

```yaml
runtime:
  phases:
    metrics:
      commands:
        - app/project-package/commands/collect-metrics.sh
```

このコマンドはプロジェクト所有のレポート用 hook である。通常のワーカー要求環境を受け取り、`command_intent=metrics_collection` が入る。stdout に JSON オブジェクトを 1 つ出す必要がある。オブジェクトには次を含められる。

```json
{
  "code_changes": { "lines_added": 10, "lines_deleted": 2, "files_changed": 1 },
  "tests": { "passed_count": 12, "failed_count": 0, "skipped_count": 1 },
  "coverage": { "line_percent": 84.2 },
  "timing": {},
  "cost": {},
  "custom": { "suite": "smoke" }
}
```

A2O は保存時に runtime context から `task_ref`、`parent_ref`、`timestamp` を追加する。コマンド出力にこれらのメタデータが含まれる場合は、runtime context と一致していなければならない。各トップレベルセクションは JSON オブジェクトでなければならない。不正 JSON、未知のトップレベルセクション、不正なセクション形状は、verification diagnostics の `metrics_collection` に記録される。成功済みの検証結果は隠さない。

保存された record は次で export できる。

```sh
a2o runtime metrics list --format json
a2o runtime metrics list --format csv
a2o runtime metrics summary
a2o runtime metrics summary --group-by parent --format json
a2o runtime metrics trends --group-by parent --format json
```

### 通知 hook

`runtime.notifications` は任意設定である。構造化された通知イベントを受け取る、プロジェクト所有のコマンドを宣言する。A2O はイベントを発火するだけで、外部システムへどう通知するかは project package が決める。

```yaml
runtime:
  notifications:
    failure_policy: best_effort # best_effort または blocking
    hooks:
      - event: task.blocked
        command: [app/project-package/commands/notify.sh]
      - event: task.completed
        command: [app/project-package/commands/notify.sh]
```

`failure_policy` の既定値は `best_effort` である。`best_effort` ではコマンド失敗を evidence に記録し、タスク進行は継続する。`blocking` では失敗を記録し、task/run 遷移を保存した後に runtime command を失敗させる。

hook の `command` は、空でない文字列だけを含む空でない配列でなければならない。A2O は準備済みワークスペースでコマンドを実行し、次を公開する。

- `A2O_NOTIFICATION_EVENT_PATH`: JSON event payload のパス

payload は schema `a2o.notification/v1` を使う。

```json
{
  "schema": "a2o.notification/v1",
  "event": "task.blocked",
  "task_ref": "A2O#283",
  "task_kind": "child",
  "status": "blocked",
  "run_ref": "run-123",
  "phase": "review",
  "terminal_outcome": "blocked",
  "parent_ref": "A2O#280",
  "summary": "worker result schema invalid",
  "diagnostics": {}
}
```

初期実装で発火するイベントは、`task.phase_completed`、`task.blocked`、`task.needs_clarification`、`task.completed`、`task.reworked`、`parent.follow_up_child_created` である。`task.started`、`runtime.idle`、`runtime.error` は、後続の scheduler-level hook point 用に予約されたイベント名である。

hook 実行 record は、stdout、stderr、exit status、実行時間、command、event、payload path とともに、最新 phase execution diagnostics の `notification_hooks` に保存される。

通常のパッケージでは実装フェーズとレビューフェーズを定義する。

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

これは内部的に固定の標準入力バンドル用実行コマンドへ展開される。`prompt_transport`、`result`、`schema`、`default_profile` は A2O の実装詳細であり、有効な `project.yaml` 項目ではない。

新しいパッケージは実行コマンドブロックを手書きせず、生成テンプレートから始める。

```sh
a2o project template \
  --package-name my-product \
  --kanban-project MyProduct \
  --language node \
  --executor-bin your-ai-worker \
  --with-skills \
  --output ./project-package/project.yaml
```

テンプレートはフェーズ単位の実行コマンド形式を使う。`--language` は `agent.required_bins` を制御する。`--executor-bin` と繰り返し指定できる `--executor-arg` は、実装フェーズとレビューフェーズの実行コマンドを生成する。

### AI CLI のワークスペース制限

A2O が agent-materialized workspace を使う場合、実装フェーズの作業場所は A2O が作成した `ticket_workspace` である。AI CLI の実行コマンドは、このワークスペースを作業ルートとして使い、メインの working tree を直接編集しないように設定する。

Codex CLI を使う場合は、`{{workspace_root}}` を作業ルートにし、workspace 内だけを書き込み可能にする。

```yaml
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - codex
          - exec
          - --cd
          - "{{workspace_root}}"
          - --sandbox
          - workspace-write
          - --output-last-message
          - "{{result_path}}"
```

追加の書き込み先が本当に必要な場合だけ `--add-dir` で明示する。メイン working tree を `--add-dir` に含めない。`--dangerously-bypass-approvals-and-sandbox` は workspace 外書き込みを防げなくなるため、本番の A2O executor では使わない。

GitHub Copilot CLI を使う場合は、Copilot CLI の許可パスを `ticket_workspace` に寄せる。A2O stdin bundle を読み、最終的な worker result JSON を stdout に出す契約を保てないなら、`project.yaml` から Copilot を直接呼ばない。生成された command-worker ラッパーの後ろで Copilot を呼ぶ。

```sh
a2o worker scaffold --language command --output ./project-package/commands/a2o-command-worker
```

```yaml
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - ./project-package/commands/a2o-command-worker
          - --schema
          - "{{schema_path}}"
          - --result
          - "{{result_path}}"
```

委譲先のコマンドは、`a2o-command-worker` が渡す stdin bundle を読み、その依頼内容を Copilot に渡し、最終的な A2O worker result JSON を stdout に出す。委譲先の Copilot 呼び出しには `--add-dir "$A2O_WORKSPACE_ROOT"` を含め、メイン working tree は追加しない。

Copilot CLI では Codex の `workspace-write` と同等の sandbox mode は確認できない。`--allow-all-paths`、`--allow-all`、`--yolo` はパス制限を弱めるため、A2O executor では避ける。Copilot CLI で workspace 外書き込みを強く防ぎたい場合は、CLI 単体の許可設定だけに頼らず、コンテナ、VM、Docker sandbox など外側の隔離環境で実行する。

どの AI CLI を使う場合でも、`source alias` のメイン working tree は worktree 作成と merge の入力であり、agent が直接編集する場所ではない。

`--output` がファイルを指す場合、生成器は `project.yaml` を書く。`--with-skills` を付けると、実装、レビュー、親タスクレビューの初期スキルも書き、生成した親タスク用スキルを参照する `parent_review` フェーズを追加する。カンバン初期化データは `kanban.project`、`kanban.labels`、`repos.<slot>.label` から導出される。A2O が管理するレーンと内部調整ラベルは `a2o kanban up` が用意する。

`project.yaml` は通常の本番運用プロファイルである。検証用プロファイルは `project-test.yaml` のような別ファイルにしてよいが、利用時は `a2o project validate --config project-test.yaml` または `a2o runtime run-once --project-config project-test.yaml` で明示的に選択する。

`runtime.phases.merge` はマージ方針と本流のターゲット参照を持つ。マージ先は A2O がタスク構造から導出するため、利用者は設定しない。

`task_templates` は検証と導入支援のための任意メタデータである。タスクテンプレートの項目は Markdown のタスクテンプレートを指す。ランタイムのタスク選択は引き続きカンバンから行う。タスクテンプレートは既定では自動登録されない。

## 参照用プロダクトの例

### TypeScript API / Web

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
      policy: ff_only
      target_ref: refs/heads/main
```

### Go API / CLI

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
      policy: ff_only
      target_ref: refs/heads/main
```

### Python サービス

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
      policy: ff_only
      target_ref: refs/heads/main
```

### 複数リポジトリのフィクスチャ

```yaml
schema_version: 1
package:
  name: a2o-reference-multi-repo
kanban:
  project: A2OReferenceMultiRepo
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
      policy: ff_only
      target_ref:
        default: refs/heads/main
```

## 現在の契約

1. `project.yaml` のスキーマバージョン `1` が公開設定の契約である。
2. ランタイムブリッジは `runtime.phases` と、`runtime.notifications` などの任意 runtime 拡張から、内部ランタイム用のパッケージデータを導出する。
3. 参照用プロダクトパッケージは単一ファイルの `project.yaml` を使う。
4. パッケージ読み込みは、未対応の分割設定ファイルを拒否する。
5. パッケージスキーマ、ドキュメント、通常診断は A2O 向けの名前を使う。
