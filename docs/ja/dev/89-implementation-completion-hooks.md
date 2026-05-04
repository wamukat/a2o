# Implementation Completion Hooks

この設計は `runtime.phases.implementation.completion_hooks` を定義する。これは implementation worker が結果を返した後、A2O がその実装を review へ進めてよいと判断する前に実行する project package の拡張点である。

## 問題

A2O には verification / remediation command があり、v0.5.70 では `publish.commit_preflight.commands` も追加された。しかし、これらは implementation completion gate ではない。

`publish.commit_preflight.commands` は publish commit の直前に実行される。publish を止めることはできるが、worker はすでに成功を返しているため、implementation AI への feedback loop としては遅すぎる。

必要なのは次の間に project-defined command を強制実行することである。

1. AI implementation worker が編集を終え、worker result を返す。
2. A2O が implementation を受理し、implementation commit を publish し、review へ進む。

hook が失敗した場合、A2O は reviewer review へ進めず、その結果を implementation rework として AI に戻す。

## ユーザー向け設定

公開設定は implementation phase 配下に置く。

```yaml
runtime:
  phases:
    implementation:
      completion_hooks:
        commands:
          - name: fmt
            command: ./project-package/commands/fmt-apply.sh
            mode: mutating
          - name: verify
            command: ./project-package/commands/impl-verify.sh
            mode: check
            on_failure: rework
```

`commands` は順序付きリストである。各要素は次の項目を持つ。

- `name`: log、diagnostics、feedback に使う安定した hook 識別子。
- `command`: host agent が実行する shell command 文字列。
- `mode`: `mutating` または `check`。
- `on_failure`: 初期実装では `rework`。他の値は state semantics を明確にしてから追加する。

MVP では `runtime.phases.implementation` の hook だけを受け付ける。review、verification、merge hook は別の設計課題である。

## 実行位置

agent-materialized implementation job の lifecycle は次のようになる。

1. workspace を materialize する。
2. implementation worker command を実行する。
3. worker result と artifact を読み込む。
4. `implementation.completion_hooks` を実行する。
5. slot evidence と canonical changed files を更新する。
6. implementation commit を publish する。
7. implementation result を runtime control plane に submit する。

hook は publish 前に実行する。publish 後ではない。これにより mutating hook の変更を implementation commit に含められ、hook 失敗を reviewer phase 開始前に implementation rework feedback として扱える。

## Command Workspace

MVP では、各 hook を edit-target repo slot ごとに 1 回、その slot checkout root で実行する。agent は次の環境変数を提供する。

- `A2O_WORKSPACE_ROOT`: materialized workspace の root。
- `A2O_COMPLETION_HOOK_NAME`: 設定された hook 名。
- `A2O_COMPLETION_HOOK_SLOT`: 現在の repo slot。
- `A2O_COMPLETION_HOOK_MODE`: `mutating` または `check`。
- `A2O_WORKER_REQUEST_PATH`: 利用可能な場合の worker request JSON path。
- `A2O_WORKER_RESULT_PATH`: 利用可能な場合の worker result JSON path。

複数 repo の文脈が必要な command は `A2O_WORKSPACE_ROOT` と request JSON の `slot_paths` map を使う。具体的な multi-repo use case が必要になった段階で、将来 `scope: workspace` mode を追加できる。

## Mutating Hook と Check Hook

`mode: mutating` は現在の edit-target slot 配下のファイル変更を許可する。format、generated code、その他 implementation commit に含めたい決定的な後処理に使う。

mutating hook が成功した後、A2O は workspace evidence と canonical changed files を再取得する。implementation publish は AI worker が返した `changed_files` だけでなく、hook 後の canonical changed files を使う。

`mode: check` は非変更コマンドである。A2O は command の前後で git state を snapshot する。check hook が staged または unstaged repo state を変更した場合、A2O は hook failure として扱い、rework feedback を返す。意図的にファイルを書き換える command は `mode: mutating` を使う。

## Failure と Rework

hook failure は task を review へ進めない。

hook が非ゼロ終了、timeout、または `mode: check` 違反を起こした場合、agent は次のような implementation execution result を submit する。

```json
{
  "success": false,
  "rework_required": true,
  "failing_command": "completion_hook:verify",
  "observed_state": "implementation_completion_hook_failed",
  "diagnostics": {
    "completion_hooks": [
      {
        "name": "verify",
        "slot": "app",
        "mode": "check",
        "exit_code": 1,
        "stdout": "...",
        "stderr": "..."
      }
    ]
  }
}
```

implementation の `rework_required=true` は runtime outcome として `rework` にする。これは既存の review-to-implementation feedback と同じ形である。次の implementation request には、hook diagnostics を `phase_runtime.prior_review_feedback` または後継の feedback field として渡し、AI が Kanban comment の自由テキストを解析せずに失敗理由を扱えるようにする。

`prior_review_feedback` という名前は歴史的に review 固有である。互換性のために使い続けることはできるが、新しい永続 evidence では `prior_phase_feedback` のような中立的概念を優先する。

## Observability

completion hook の実行は operator から確認できる必要がある。

- host-agent event log に `completion_hook_start`、`completion_hook_done`、`completion_hook_error` を出す。
- hook output が非空または hook が失敗した場合、combined log artifact を保存する。
- `describe-task` execution diagnostics に hook status、slot、mode、failing command を含める。
- 失敗時は既存の blocked / rework comment path で Kanban activity に残す。
- `watch-summary --details` で reviewer review ではなく implementation rework 待ちであることが分かる structured data を残す。

通常の `watch-summary` に hook ごとの詳細行は不要である。

## Publish Commit Preflight との関係

`runtime.phases.implementation.completion_hooks` と `publish.commit_preflight` は別の surface である。

- completion hooks は implementation lifecycle gate であり、AI implementation worker へ rework input を返せる。
- completion hooks は implementation publish commit 前に実行する。
- `mode: mutating` を指定した completion hooks はファイル変更を許可する。
- `publish.commit_preflight.commands` は最後の publish safety check であり、check-only でなければならない。
- preflight failure は publish を止めるが、AI feedback の主経路としては扱わない。

project は両方を使える。典型的には、completion hooks を format / test feedback に使い、publish preflight を最後の非変更 guardrail として残す。

## Acceptance Criteria

- project package validation が文書化した schema を受け付け、壊れた hook を拒否する。
- hook 設定が `project.yaml` から host launcher、runtime、Ruby workspace request、Go agent request へ伝播する。
- agent-materialized implementation job が publish 前に hook を実行する。
- mutating hook の変更が implementation commit に含まれる。
- check hook がファイルを変更した場合は失敗する。
- hook failure は implementation rework に流れ、review へ進まない。
- ユーザー向けドキュメントが設定方法と運用方法を説明する。
