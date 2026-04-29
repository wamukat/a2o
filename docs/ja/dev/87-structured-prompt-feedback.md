# 構造化 Prompt Feedback 設計

## Status

将来向けの設計である。初回の project-package prompt configuration release をブロックしない。

## Goal

prompt guidance が不足した箇所や失敗した箇所を構造化 evidence として収集し、project-package maintainer が後から prompt / skill を改善できるようにする。初期版は read-only / reporting-oriented とし、prompt file を自動で書き換えない。

## Event Model

各 feedback event は task、run、phase、prompt identity、observed outcome に紐づける。

```json
{
  "event_type": "review_finding",
  "severity": "warning",
  "task_ref": "A2O#123",
  "run_ref": "run-abc",
  "phase": "review",
  "prompt": {
    "profile": "implementation_rework",
    "effective_profile": "implementation",
    "fallback_profile": "implementation",
    "repo_slot": "app",
    "schema_version": "1",
    "composed_instruction_sha256": "..."
  },
  "category": "missing_verification",
  "summary": "Implementation did not run the focused test named in the ticket.",
  "source": "review_result",
  "evidence_ref": "agent-artifact:..."
}
```

初期の `event_type` は次を想定する。

- `schema_invalid`: worker result JSON の必須 field や identity が不正。
- `unclear_requirement`: worker が human clarification を要求した、または期待動作を推定できなかった。
- `review_finding`: review が bug、acceptance coverage 不足、危険な互換性変更、missing tests を検出した。
- `rework_required`: review feedback を満たすため implementation の再実行が必要になった。
- `missing_verification`: implementation / remediation に期待する証跡が不足した。
- `excessive_scope`: worker が意図した ownership 外の file / module を変更した。
- `unsafe_instruction_conflict`: project / ticket guidance が A2O schema、workspace、branch、Kanban、review、verification constraint を上書きしようとした。
- `human_clarification_needed`: product decision または operator decision がないと進められない。

推奨 `category` は free-form prose ではなく安定した文字列にする。例: `schema_invalid`、`ambiguous_requirement`、`acceptance_gap`、`missing_test`、`missing_verification`、`compatibility_risk`、`scope_creep`、`unsafe_override`、`docs_gap`、`migration_gap`、`human_decision`。

## Capture Points

- Implementation: invalid result schema、excessive scope、missing verification、unsafe instruction conflict。
- Review: finding category、severity、affected file/path、rework required の有無。
- Rework: prior review finding に対応できたか、繰り返し発生した finding category、新規 regression。
- Decomposition: unclear requirement、child draft rejected、missing ownership、excessive child scope。
- Parent review: child integration gap、sequencing conflict、duplicated child work、migration / release guidance 不足。

## Storage

通常の Kanban comment を簡潔に保つため、保存先を分ける。

- Run artifact: 正本となる JSONL feedback record。分析用の durable source とする。
- Execution diagnostics: count summary と prompt identity field だけを載せる。
- Kanbalone structured log または ticket comment: `prompt_feedback category=missing_verification count=1 prompt=implementation_rework sha256=...` のような summary を描画する。

通常の Kanban comment には raw prompt body を保存しない。raw worker request artifact は既存の artifact retention / access policy に従う。

## Prompt Fingerprint Linkage

各 event には worker evidence で記録される prompt metadata を埋め込む。

- requested `profile`
- `effective_profile`
- 存在する場合の `fallback_profile`
- 存在する場合の `repo_slot`
- project package schema version
- composed instruction SHA-256 と byte count
- layer ごとの kind、title/path、SHA-256、byte count

これにより、現在の filesystem を読まなくても run 間の prompt 変更を検出できる。

## User-Visible Surfaces

初期の read-only surface は次の通り。

- `describe-task`: 直近の feedback category と、それを生んだ prompt fingerprint を表示する。
- `watch-summary --details`: details 指定時だけ blocked / rework の compact feedback category を表示する。
- 将来の `runtime prompt-feedback list`: category、prompt profile、repo slot、task、parent で filter する。
- 将来の `runtime prompt-feedback export`: offline prompt tuning 用に JSONL / CSV export する。

初期実装では draft prompt edit を作らない。将来 prompt / skill 変更を提案する場合も、review 可能な artifact または ticket として扱う。

## Non-Goals

- prompt の自動書き換え。
- runtime feedback から project-package prompt file を直接変更すること。
- すべての review finding を prompt failure とみなすこと。code、test、product、ticket quality が原因の場合もある。
- Kanban comment に raw prompt content を保存すること。

## Open Questions

- feedback record を既存の analysis artifact root に置くか、専用 prompt-feedback store に置くか。
- Kanbalone に first-class structured feedback field を追加するか、初回は rendered comment のみにするか。
- prompt feedback artifact の retention を AI raw log / execution metadata とどう揃えるか。

