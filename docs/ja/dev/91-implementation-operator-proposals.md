# 実装フェーズの operator proposal

この文書は A2O#603 / GH#94 の設計を定義する。実装 worker が現在のタスクを完了しつつ、プロジェクトのルールや運用への改善提案を operator に届けたい場合の構造化ルートである。

## 問題

実装中の AI worker は、要求された変更を完了しながら、実はプロジェクトポリシー、アーキテクチャルール、lint ルール、依存関係ポリシー、ツール設定の方を改善すべきだと気づくことがある。

例:

- 依存関係ルールで禁止されているため不自然な回避実装をしたが、その依存を許可する方が自然である。
- 行長制限に合わせるために読みにくい分割をしたが、プロジェクトの制限値を見直す方がよい。
- タスクは完了したが、project command、verification policy、runtime policy、architecture rule を調整すると次回以降の作業が楽になる。

現在は `summary` に自由記述するしかなく、operator が見落としやすい。`follow_up_child` を使うと、提案ではなく実作業として扱われてしまう。

## 設計判断

MVP では worker result に optional な `operator_proposals` フィールドを追加する。新しい `implementation-proposal` フェーズは追加しない。

理由:

- 提案は operator に見えるべきだが、現在のタスク成功を変えるものではない。
- 提案のためだけに scheduler、phase model、review 遷移、merge 経路を増やすのは時期尚早である。
- decomposition の `author-proposal` / `review-proposal` は実装計画 artifact を作るためのものであり、実装後の operator proposal とは目的が違う。

## 既存フィールドとの境界

`operator_proposals` は、現在のタスクとは別に、人間がプロジェクト、プロセス、ポリシー、アーキテクチャ改善を検討すべきと worker が判断したときに使う。

適している対象:

- project command、verification policy、runtime policy、architecture rule の改善提案
- 今後の A2O 実行を楽にする process / operating policy 調整
- operator には有益だが、自動で runnable work にすべきではない代替案

次の場合は使わない。

- 直接のコード follow-up を runnable な実装作業にしたい場合: `review_disposition.kind=follow_up_child` または既存の follow-up child 経路を使う
- prompt や skill の再利用可能な改善候補: `skill_feedback` を使う
- 変更したコード内の設計負債: `refactoring_assessment` を使う
- タスクを止めるべき曖昧さ: `clarification_request` を使う
- 実装失敗または rework feedback: `success=false` と通常の failure fields を使う

概念が別であれば、同じ worker result に `operator_proposals` と他の専用フィールドが共存してよい。たとえば、今回のコード重複には `refactoring_assessment` を使い、回避実装を生んだ lint ルール見直しには `operator_proposals` を使う。

## Worker Result Contract

`operator_proposals` は optional であり、省略、`null`、empty array、または proposal entry の配列を許容する。empty array は proposal なしと同等であり、evidence や comment を出してはならない。

各 entry の MVP 形状:

```json
{
  "title": "infrastructure annotation の ArchUnit rule 緩和",
  "summary": "現在の workaround は有効だが、実装が不自然になっている。",
  "description": "infrastructure package で対象 annotation を許可すれば、依存方向を保ったまま workaround を削除できる。",
  "category": "architecture_policy",
  "priority": "low",
  "scope": ["repo_alpha:src/main/java/com/example/infrastructure"],
  "evidence": ["禁止 annotation を避けるため FooAdapter を変更した。"],
  "suggested_action": "ArchUnit rule を確認し、この annotation を許可すべきか判断する。"
}
```

必須フィールド:

- `title`
- `summary`

任意フィールド:

- `description`
- `category`
- `priority`: `low`、`medium`、`high`、`urgent`
- `scope`: repo slot、path、package、command、policy 名などの配列
- `evidence`: 短い文字列の配列
- `suggested_action`

必須フィールドが存在し、文字列が空でないことを確認したうえで、任意の unknown fields は将来拡張として許容してよい。壊れた proposal entry は operator 向け証跡を不可靠にするため、worker-result validation で失敗させる。

## ライフサイクル

implementation success の場合:

1. implementation worker が valid worker result を返す。
2. A2O が既存の worker result contract と一緒に `operator_proposals` を検証する。
3. A2O が proposals を execution evidence と worker-result artifacts に保存する。
4. proposal が 1 件以上ある場合、A2O が implementation completion Kanban comment に短い Markdown section を追記する。
5. タスクは通常の implementation-to-review 経路を進む。

proposal は以下をしてはならない。

- `success` を変更する
- `rework_required` を強制する
- child ticket を自動作成する
- trigger label を付ける
- parent/child scheduling を変える

implementation failure の場合、MVP では valid proposal を evidence に保存してもよいが、通常の operator proposal コメントは投稿しない。operator の直近の対応対象は failure / rework 経路である。

## Kanban コメント

comment section は Markdown で短くする。最大 3 件の proposal を要約し、詳細は `describe-task` で確認できるようにする。

例:

```markdown
### A2O operator proposals

実装は完了し、ブロックしない提案が 1 件報告されました。

1. **infrastructure annotation の ArchUnit rule 緩和** (`low`, `architecture_policy`)
   現在の workaround は有効だが、実装が不自然になっている。

詳細は `a2o runtime describe-task A2O#123` で確認できます。
```

固定文言の既定は英語である。`kanban.system_comment_locale: ja` を使うと固定ラベルを日本語で表示する。proposal の title / summary は worker が書いた内容なので、A2O が機械翻訳しない。

## Runtime 表示

`a2o runtime describe-task <task-ref>` は latest execution diagnostic の下に pending operator proposals を表示する。通常の `watch-summary` には proposal 詳細を表示しない。

表示項目:

- proposal count
- title
- priority
- category
- suggested action
- evidence path または artifact reference

必要になれば将来 `watch-summary --details` で件数だけを表示する。

## 将来拡張

MVP の対象外:

- `a2o runtime operator-proposals list`
- `a2o runtime operator-proposals convert-to-ticket`
- category ごとに comment 可否を制御する project-package policy
- high priority proposal に reviewer を要求する project-package policy
- comment-only では不十分だと分かった後の専用 proposal review phase

## 実装タスク

実装時の子チケット候補:

1. `operator_proposals` の worker result schema と semantic validation を追加する。
2. proposal を execution evidence と `describe-task` に保存・表示する。
3. implementation success proposal の localized Markdown Kanban コメントを出力する。
4. project script contract、user docs、release notes を更新する。
5. `operator_proposals` を含む worker result の unit test と real-task smoke coverage を追加する。
