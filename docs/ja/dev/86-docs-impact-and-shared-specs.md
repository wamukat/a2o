# Docs impact と共通仕様ドキュメント

この文書は、A2O が実装成果物としてドキュメント更新を扱うための設計を定義する。

A2O に設計フェーズを常設するのではなく、実装・レビュー・親レビューの中で `docs-impact` を判断し、必要な設計知識、共通仕様、外部仕様、背景、トレーサビリティをプロジェクトのドキュメント体系へ蓄積する。

## 1. 問題

A2O はチケットを分解し、実装し、レビューできる。しかし、設計判断や共通仕様がコードとチケットコメントだけに残ると、次の問題が起きる。

- 人間が機能の構造や背景を追いにくい。
- AI が既存の共通機能を見落とし、似て非なる機能を重複実装しやすい。
- DB 定義、外部 API ACL、project-package schema、runtime event model などの共通仕様が分散する。
- 外部 I/F 仕様や利用者向け仕様が実装と乖離する。
- どの要件や remote issue から機能が生まれたのか追跡しづらい。

必要なのは重い設計承認フェーズではなく、開発成果物としての体系的なドキュメント更新である。

## 2. 目的

- project-package が docs root、docs repo、カテゴリ、索引、正本を宣言できる。
- A2O がチケットごとに docs-impact を判断できる。
- 実装・レビュー・親レビューで必要な docs 追加 / 更新を扱える。
- 共通仕様ドキュメントを AI worker の実装前コンテキストとして使える。
- 要件、親チケット、remote issue、実装チケット、関連 docs のトレーサビリティを残せる。
- 人間が読む体系的な目次を維持できる。
- 外部 I/F 仕様や DB 仕様など、正本が別にある領域では正本を尊重する。

## 3. 非目的

A2O は docs platform にならない。

- ドキュメントサイト生成機能は持たない。
- 文書承認ワークフローは持たない。
- 複雑な公開管理、権限管理、読者別ポータル、検索 UI は持たない。
- OpenAPI、Javadoc、TypeDoc、DB migration、GraphQL schema など専門ツールの代替にならない。
- すべてのチケットにドキュメント更新を強制しない。

A2O の責務は、docs-impact の判断、関連 docs の参照、必要な Markdown / spec 更新、索引更新、証跡、レビュー確認までである。

A2O は次を暗黙に所有しない。

- docs の公開先
- navigation site の完全生成
- 文書の承認状態
- 翻訳の完全性
- チーム内の docs ownership

これらが必要な project では、project-package の docs policy と外部ツールに委ねる。

## 4. Project-package docs 設定

project-package は docs の場所と体系を宣言する。

```yaml
docs:
  root: docs
  index: docs/README.md
  policy: docs/policy.md
  categories:
    architecture: docs/architecture
    shared_specs: docs/shared-specs
    frameworks: docs/frameworks
    data_model: docs/data-model
    acl: docs/integrations/acl
    interfaces: docs/interfaces
    features: docs/features
    decisions: docs/decisions
    operations: docs/operations
    migration: docs/migration
```

docs が別 repo slot にある場合は、repo slot と root を指定する。

```yaml
docs:
  repoSlot: docs
  root: docs
  index: docs/README.md
```

`repoSlot` がない場合、docs は primary repo slot の中にあるとみなす。A2O は docs path を project-package root ではなく、対象 repo slot の checkout 内で解決する。

docs repo を更新するには、その repo が A2O の repo slot として宣言されていなければならない。A2O は未宣言の外部 docs repository を直接 clone / push しない。

## 4.1 検証ルール

docs config は prompt / skill config と同じく厳格に検証する。

- `root`、`index`、category path、authority path は対象 repo slot 内の相対 path である。
- absolute path、`..` による repo 外参照、symlink escape は拒否する。
- `repoSlot` は既存 repo slot と一致しなければならない。
- category id は空でなく、一意で、安定した machine-readable key である。
- docs root が存在しない場合は、project policy に従って作成するか、明確な configuration error にする。
- front matter schema version がある場合、A2O が認識できない version は warning または error として扱う。
- authority source は存在する path、または生成物であることを project policy が明示する。

検証は docs 更新時だけでなく、`doctor` 相当の診断でも確認できるようにする。

## 5. ドキュメントカテゴリ

初期カテゴリは次を想定する。

| category | 目的 |
| --- | --- |
| `architecture` | システム構造、境界、主要コンポーネント、データフロー。 |
| `shared_specs` | AI が独自実装を増やさないための共通仕様。 |
| `frameworks` | プロダクト固有フレームワーク、共通ライブラリ、拡張ポイント。 |
| `data_model` | DB、永続化、ドメインモデル、migration 方針。 |
| `acl` | 認可、認証、permission、role、access control policy。 |
| `external_api` | 外部 API 呼び出し、integration contract、adapter / anti-corruption layer、retry 方針。 |
| `interfaces` | 外部 I/F、API、CLI、イベント、設定 schema。 |
| `features` | 利用者から見た機能仕様。 |
| `decisions` | なぜその構造にしたか、捨てた案、トレードオフ。 |
| `operations` | 運用、障害対応、設定、リリース、監視。 |
| `migration` | 互換性、移行手順、破壊的変更の扱い。 |

カテゴリは project-package で追加できる。ただし A2O core は上記カテゴリを first-class な候補として扱い、docs-impact 判定や review prompt の語彙に使う。

## 6. 共通仕様ドキュメント

`shared_specs` は、AI が似た機能を重複実装しないための制約面である。

例:

- runtime event model
- Kanban ticket state model
- project-package config schema
- prompt composition model
- workspace / branch / repo slot model
- DB schema / domain model
- external API ACL 方針
- error handling / retry / validation policy
- logging / evidence / trace model

A2O は実装前に関連する共通仕様を探し、worker request の参照コンテキストに含める。worker には、既存共通仕様に反する独自実装を増やさないよう指示する。

新しい共通機能や共通境界を作る場合は、実装と同じ branch 上で `shared_specs` または該当カテゴリを追加 / 更新する。

## 7. 正本と派生ドキュメント

すべての情報を Markdown が正本にするわけではない。

project-package は authority を宣言できる。

```yaml
docs:
  authorities:
    db_schema:
      source: db/migrate
      docs: docs/data-model
    http_api:
      source: openapi.yaml
      docs: docs/interfaces/http-api.md
    graphql_api:
      source: schema.graphql
      docs: docs/interfaces/graphql-api.md
    cli:
      source: lib/cli
      docs: docs/interfaces/cli.md
    shared_runtime:
      docs: docs/shared-specs/runtime.md
```

正本がある場合、A2O は正本更新を優先し、Markdown は説明、背景、運用、読者向け整理として扱う。たとえば OpenAPI が正本の HTTP API では、Markdown だけを更新して仕様変更を済ませてはならない。

正本の優先順位は曖昧にしない。

```text
declared authority source
  > project-package docs
  > generated evidence / artifacts
  > ticket text / comments
```

project-package が個別 authority の例外を宣言していない限り、この順序を使う。docs と正本が矛盾する場合、A2O は docs だけを修正して通過させず、review finding または rework にする。

## 8. Front matter とトレーサビリティ

A2O が管理する docs は、可能なら front matter を持つ。

```markdown
---
title: Prompt Composition Model
category: shared_specs
audience:
  - maintainer
  - ai_worker
status: active
related_requirements:
  - A2O#371
related_tickets:
  - A2O#372
  - A2O#374
authorities:
  - project_package_schema
---
```

必須候補:

- `title`
- `category`
- `status`
- `related_requirements`
- `related_tickets`

任意候補:

- `audience`
- `source_issues`
- `authorities`
- `owners`
- `updated_by`
- `supersedes`

A2O は front matter を使って、要件から docs、docs から実装チケット、実装チケットから背景を辿れるようにする。

front matter は lifecycle state の正本ではない。Kanban の current state、review disposition、run status、merge status は evidence / ticket comment / runtime state が正本である。docs front matter には、長期的に意味が残る requirement ref、source issue、related ticket、authority、status だけを置く。

## 8.1 多言語ドキュメント

project-package は、多言語 docs の扱いを宣言できる。

```yaml
docs:
  languages:
    canonical: ja
    mirrored:
      - en
    policy: require_canonical_warn_mirror
```

初期方針は、canonical docs の更新を必須とし、mirror docs は project policy に応じて次のいずれかにする。

- `require_all`: すべての言語を同じ branch で更新しなければならない。
- `require_canonical_warn_mirror`: canonical は必須、mirror は warning / follow-up。
- `canonical_only`: A2O は canonical のみ更新する。

A2O 自身の docs は `ja` と `en` が並行しているため、A2O project-package では少なくとも mirror debt を evidence に残す必要がある。

## 9. Docs-impact 判定

implementation worker は、チケット処理中に docs-impact を判断する。

docs-impact ありの典型例:

- 新しい runtime concept を追加する。
- project-package config / schema / prompt / skill surface を増やす。
- Kanban 状態遷移、label の意味、scheduler ルールを変える。
- multi-project / multi-repo / branch / workspace / repo slot 境界に触る。
- DB schema、外部 API、CLI、設定 schema、event schema を変える。
- 共通ライブラリ、プロダクト固有 framework、ACL を追加 / 変更する。
- 既存設計の方針を変える。
- 今後の AI worker が迷いそうな判断をした。

docs-impact なしの典型例:

- 既存仕様の範囲内の小さな bug fix。
- 内部実装の局所的な修正で、共通境界や利用者挙動を変えない。
- ドキュメント済み仕様に沿った単純な実装。

判断が曖昧な場合、worker は docs-impact を `maybe` として evidence に残し、review に判断を委ねる。

docs-impact の severity は project policy で調整できる。

```yaml
docs:
  impactPolicy:
    shared_specs: block_review
    interfaces: block_review
    data_model: block_review
    decisions: warn
    features: warn
```

`block_review` は不足時に review finding / rework を要求する。`warn` は evidence と comment に残し、parent review で follow-up ticket にしてよい。

## 10. 実装フローでの扱い

### 10.1 事前参照

worker request composition は、チケット本文、repo slot、phase、関連要件から docs candidate を探す。

- category match
- front matter の `related_requirements`
- source issue / parent ticket / child ticket relation
- repo slot / authority
- project-package docs policy

候補 docs は worker に「参照すべき共通仕様」として渡す。大量の全文を渡すのではなく、まず path / title / summary / relevant excerpt を渡し、必要に応じて worker が読む。

worker request には少なくとも次を含める。

- docs config summary
- candidate docs path / title / category / reason
- relevant authority sources
- expected docs actions
- docs-impact policy と severity
- traceability refs
- 多言語 policy

`docs_context` は任意であり、`docs` config がない project では出力しない。存在する場合は implementation、review、parent review の worker request に載せる。decomposition command も、既存の shared spec を踏まえて child ticket を起案する必要がある場合は同じ形を受け取れる。

worker result には構造化された `docs_impact` object を含められる。A2O は docs 更新を全タスクに強制せず、object の形だけを検証する。

- `disposition`: `yes` / `no` / `maybe`
- `categories`: 判断対象になった docs category
- `updated_docs`: worker が変更した docs path
- `updated_authorities`: 更新または確認した正本
- `skipped_docs`: 意図的に更新しなかった `{ path, reason }`
- `matched_rules`: 判断根拠となった rule
- `review_disposition`: docs 判断に対する review outcome
- `traceability`: 関連要件、ticket、source issue

review phase で `docs_impact.disposition` が `yes` または `maybe` の場合、`review_disposition` は `accepted` / `warned` / `blocked` / `follow_up` のいずれかを必須とする。`blocked` は child review では rework へ戻す。`follow_up` は parent review でのみ有効であり、top-level の `follow_up_child` disposition と一致していなければならない。docs debt を成功扱いで消さない。

### 10.2 実装時更新

docs-impact がある場合、implementation worker は実装 branch 上で docs を追加 / 更新する。

更新対象:

- 対象カテゴリの Markdown
- 正本 spec
- index / TOC
- front matter
- migration / operations note

### 10.3 Review

review worker は次を確認する。

- docs-impact 判断が妥当か。
- 既存共通仕様に反した独自実装を増やしていないか。
- 変更した外部 I/F、DB、CLI、config、event が正本と docs に反映されているか。
- docs front matter と traceability が残っているか。
- index / TOC が更新されているか。

### 10.4 Parent review

parent review は、子チケット群全体として docs が体系的かを見る。

- 複数 child が同じ共通仕様を別々に書いていないか。
- 親要件から機能仕様、共通仕様、実装チケットへ辿れるか。
- feature docs と shared specs の責務が混ざっていないか。
- follow-up docs ticket が必要か。

## 10.5 Shared specs の扱い

shared specs は読み取り専用入力にも更新対象にもなる。

- 既存 shared spec が該当する場合、worker はそれを制約として読む。
- 実装が shared spec の変更を必要とする場合、同じ branch で shared spec を更新する。
- 既存 shared spec と矛盾する実装は、明示的な design decision 更新なしに通してはならない。

review は「既存 shared spec を使えばよいのに独自実装を増やしていないか」を確認する。

## 11. Index / TOC

A2O は最小限の index 更新を行う。

- `docs.index` が指定されている場合、新規 doc をカテゴリ別一覧へ追加する。
- 各カテゴリに README / index がある場合、該当カテゴリの一覧を更新する。
- 既存の人間編集領域を壊さないため、A2O 管理ブロックを使えるようにする。

例:

```markdown
<!-- a2o-docs-index:start category=shared_specs -->
- [Prompt Composition Model](shared-specs/prompt-composition.md)
- [Runtime Event Model](shared-specs/runtime-events.md)
<!-- a2o-docs-index:end -->
```

管理ブロックがない場合の index 更新は保守的に行い、曖昧なら docs-impact finding として review に残す。

## 12. Evidence

run evidence には docs-impact の判断を記録する。

```json
{
  "docs_impact": {
    "disposition": "yes",
    "categories": ["shared_specs", "interfaces"],
    "updated_docs": [
      "docs/shared-specs/prompt-composition.md",
      "docs/interfaces/project-package-schema.md"
    ],
    "updated_authorities": [
      "project.yaml schema"
    ],
    "skipped_docs": [
      {
        "path": "docs/en/interfaces/project-package-schema.md",
        "reason": "mirror policy allows follow-up"
      }
    ],
    "matched_rules": [
      "project_package_schema_changed"
    ],
    "review_disposition": "accepted",
    "traceability": {
      "related_requirements": ["A2O#371"],
      "related_tickets": ["A2O#372", "A2O#374"]
    }
  }
}
```

チケットコメントには要約だけを残す。

## 13. Prompt / skill 設定との関係

この設計は A2O#371 の project-package prompt / skill 設定と相性がよい。

- implementation prompt は docs-impact 判定を要求できる。
- review prompt は docs 整合性チェックを要求できる。
- repo slot addon は backend / frontend / library ごとの docs カテゴリや正本を補足できる。
- decomposition prompt は親要件から docs traceability を作る方針を child draft に含められる。

ただし docs-impact は prompt だけに依存しない。A2O runtime は evidence と review checklist に docs-impact を first-class に持つ。

## 14. チケット分割

実装は次の単位に分ける。

- project-package docs config schema と loader。
- docs front matter / index / authority model。
- docs-impact 判定と worker request への関連 docs 注入。
- implementation / review / parent_review の docs-impact evidence と checklist。
- docs 更新 helper と index 管理。
- 共通仕様 / 正本 / traceability のサンプル project-package と E2E。
- migration / user docs。
