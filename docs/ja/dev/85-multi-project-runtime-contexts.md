# マルチプロジェクト Runtime Context

この文書は、1つの A2O インストールで複数のローカルプロジェクトを扱うための最終形の設計を定義する。既存の単一プロジェクト運用は維持する。

ここで目指すのは SaaS 的な完全マルチテナントではない。A2O は引き続きローカル開発ランタイムであり、複数の project context を知り、agent session や command ごとにどの project を使うか解決できるようにする。

## 問題

現在の bootstrap 済み A2O instance は、実質的に 1つの project package、1組の repo source、1つの Kanban board、1つの storage、1つの task ref 解釈を持つ。この形は一人で1プロジェクトを扱うには安全だが、複数プロジェクトと複数 agent が同じ PC にいる形には合わない。

危険なのは設定項目を増やすことではない。project identity がすべての副作用境界に影響する点が危険である。

- project package と skill
- live repo と repo slot
- Kanban board と label 語彙
- runtime storage、evidence、metrics、logs、artifacts
- scheduler selection と lock
- branch namespace と merge target
- hook の cwd/env
- task ref と remote issue mapping

このどれかが暗黙の global のままだと、A2O がある project の ticket を処理しながら別 project の repo や board に書き込む可能性がある。

## 目的

- 1つの A2O インストールに複数の named project context を定義できるようにする。
- 既存の単一プロジェクト command behavior を default path として維持する。
- agent 自動紐付けを追加する前に、runtime state に project identity を明示する。
- agent session と手動 command が必ず1つの project context に解決されるようにする。
- project package schema は product behavior に集中させ、マルチプロジェクト登録は runtime installation config に置く。
- 副作用を project key で分離する。
- 最終形を先に設計し、実装は安全な phase に分ける。

## 非目的

- project をまたぐ remote team workflow tracking。
- 初期実装での cross-project task scheduling。
- project 間 dependency や blocker。
- project 間で共有される writable workspace。
- user authorization や SaaS multi-tenancy。
- project package に scheduler、evidence、Kanban provider behavior を再定義させること。

## 用語

`ProjectDefinition`
: ローカル project の名前、project package、repo sources、Kanban board、storage partition を指す runtime installation record。

`ProjectKey`
: project definition の安定した人間可読 id。Kanban board id や filesystem path から導出しない。

`ProjectRuntimeContext`
: 1 project の解決済み runtime context。既存の `ProjectContext` に加えて、board id、repo sources、storage paths、branch namespace、adapter clients など runtime-owned boundary を含む。

`AgentBinding`
: agent identity または session から default project key への mapping。

`ProjectRegistry`
: project definition を読み込み、project key から `ProjectRuntimeContext` を解決する runtime-owned registry。

## Target Configuration Shape

マルチプロジェクト登録は A2O runtime installation に属する。`project.yaml` には入れない。

```yaml
version: 1
default_project: a2o

projects:
  a2o:
    package_path: /Users/takuma/workspace/a2o/project-package
    storage_dir: /Users/takuma/workspace/a2o/.work/a2o/projects/a2o
    kanban:
      mode: external
      url: http://127.0.0.1:3470
      board_id: 2
      project: A2O
      task_ref_prefix: A2O
    repo_sources:
      app:
        path: /Users/takuma/workspace/a2o

  kanbalone:
    package_path: /Users/takuma/workspace/kanbalone/project-package
    storage_dir: /Users/takuma/workspace/a2o/.work/a2o/projects/kanbalone
    kanban:
      mode: external
      url: http://127.0.0.1:3470
      board_id: 4
      project: Kanbalone
      task_ref_prefix: KAN
    repo_sources:
      app:
        path: /Users/takuma/workspace/kanbalone

agent_bindings:
  codex-a:
    default_project: a2o
  codex-b:
    default_project: kanbalone
```

実際のファイル名は実装時に決めてよい。重要なのは、この config が runtime-owned installation metadata であること。project package は portable なまま、1 product の execution surface を記述する。

Kanban identity は、安定した board identity と、現行 provider/adapter が必要とする表示・ref 用 identity の両方を持つ。`board_id` は provider が board id を公開する場合の安定 identity である。`project` と `task_ref_prefix` は、`A2O` や `A2O#297` のような名前を使う既存 Kanban CLI/ref 契約を保つために必要である。

## Context Resolution

すべての command / agent request は、Kanban、Git、storage、logs、hooks、scheduler state に触る前に、必ず1つの project key に解決されなければならない。

解決順:

1. command/request で明示された project key。
2. agent session binding。
3. runtime default project。
4. legacy single-project instance。

複数 project が task ref に一致し得る場合、または project を決定できない場合、A2O は副作用の前に fail する。

解決された project key は run state、evidence、metrics、logs、workspace descriptor、agent request bundle にコピーする。process memory にだけ保持してはいけない。

## Runtime Context Contents

`ProjectRuntimeContext` は以下を持つべきである。

- `project_key`
- loaded project package path と manifest path
- 既存 domain `ProjectContext`
- repo sources と repo slot aliases
- Kanban adapter instance と board identity
- project storage root
- workspace root
- evidence/log/artifact roots
- branch namespace component
- hook execution cwd/env base
- scheduler group または lock namespace
- runtime package compatibility metadata

裸の `ProjectContext`、repo source map、storage dir、Kanban adapter を受け取る既存コードは、`ProjectRuntimeContext` またはそこから派生した narrower value を受け取る方向へ寄せる。

## Side-Effect Partitioning

project key は、すべての durable / mutable side effect を分離しなければならない。

| Boundary | 必須ルール |
| --- | --- |
| Kanban | task operation は解決済み project の board だけを使う。 |
| Git repo slots | repo alias は選択された project context 内だけで解決される。 |
| Branches | user-visible branch namespace は project key または同等に衝突しない runtime instance component を含む。 |
| Storage | runtime DB/files、evidence、metrics、logs、workspaces、artifacts は project storage root 配下に保存する。 |
| Locks | scheduler lock と task lock は project key を含む。 |
| Hooks | hook cwd/env は選択された project package と repo sources から作る。 |
| Agent requests | request payload は project key と project-scoped paths を含む。 |
| Cleanup | cleanup command は明示的に all projects を指定されない限り project storage root をまたがない。 |

## Task Ref Handling

task ref は project 間で global unique ではない。ある board の `A2O#297` と別 board の `A2O#297` は別の local task である。A2O task の durable identity は `(project_key, task_ref)` の composite identity とする。

user-facing command は以下を受け付ける。

```text
--project a2o A2O#297
a2o:A2O#297
```

project を context から解決できる場合だけ、unqualified form を許可する。曖昧な unqualified ref は fail する。

runtime state は以下を保存する。

```json
{
  "project_key": "a2o",
  "task_ref": "A2O#297",
  "kanban_board_id": 2
}
```

既存 store の互換性を守るため、古い record に `project_key` がない場合は legacy single-project context に属するものとして読む。複数 project registry が有効な状態で legacy record を曖昧に読む必要がある場合は、operator に migration を要求する。storage index は通常 read の中で legacy record を書き換えるのではなく、composite identity へ段階的に migration する。

## Scheduler Model

最終形は project context ごとに1 scheduler を持てるモデルにする。cross-project scheduling は orchestration concern であり、初期実装には含めない。

初期挙動:

- `runtime resume --project <key>` は1 project scheduler を動かす。
- `runtime watch-summary --project <key>` は1 project を表示する。
- `runtime status` は known projects を一覧してもよいが、task lifecycle operation は project-scoped のままにする。

将来 `--all-projects` を追加できるが、per-project lock、storage、reporting が安定してからにする。

## Agent Binding

agent binding は explicit project resolution の上に乗る convenience layer である。

target rules:

- agent session は default project key を持てる。
- request metadata は runtime policy が許可する場合だけ default project を override できる。
- A2O は agent 経由で作られたすべての run に project key を記録する。
- agent に binding がなく explicit project もない場合、runtime default project がない限り fail する。

agent binding は、project-scoped runtime state が durable になる前に実装してはいけない。

## Backward Compatibility

既存の単一プロジェクト install は動き続けなければならない。

compatibility rules:

- multi-project registry がなければ、A2O は現在と同じように動く。
- 既存の `.work/a2o/runtime-instance.json` は有効な single-project instance のまま。
- `project.yaml` schema に breaking change は不要。
- single-project mode では `--project` なし command が動き続ける。
- registry への migration は明示的で、operator が opt-in するまでは reversible とする。
- `tasks.json`、`runs.json`、SQLite record は `project_key` なし legacy record を読めるようにする。

## Guardrails

A2O は mismatch を検知したら fail fast する。

- task が解決済み project board と異なる board に属している
- repo slot alias が選択された project に存在しない
- hook command が選択された project package contract の外に解決される
- storage root を2つの project key が共有している
- branch namespace が別 project と衝突する
- 複数 project が active な状態で unqualified task ref を使った
- scheduler lock が同じ project ですでに取得されている
- agent queue または artifact store に project key がない job を multi-project mode で claim しようとしている

guardrail failure は worker failure ではなく configuration error として報告する。

## Implementation Phases

### Phase 0: Design And Inventory

- target model を文書化する。
- config loading、runtime services、Kanban adapters、storage、scheduler、agent requests、CLI の global assumption を棚卸しする。
- behavior はまだ追加しない。

### Phase 1: Project Registry And Explicit Context

- runtime-owned project registry type を追加する。
- registry 経由で1つの default project を扱えるようにする。
- read-only diagnostic command から `--project` parsing を追加する。
- 新しい task、run、evidence、metrics、scheduler cycle、agent job、artifact metadata、workspace descriptor、log index record に resolved project key を保存する。
- 古い record は legacy single-project interpretation で読み続ける。
- agent binding と multi-project scheduler はまだ入れない。

### Phase 2: Project-Scoped Side Effects

- storage roots、logs、workspaces、evidence、metrics、locks を project storage root 配下へ移す。
- Kanban adapter construction を project-scoped にする。
- repo source resolution を project-scoped にする。
- agent queue と artifact store を project-scoped にする。
- board/repo/storage mismatch guardrail を追加する。
- repository key、queue/artifact namespace、scheduler pid/log path、cleanup selector が project-scoped になるまで、write / lifecycle command に複数 project definition を有効化しない。
- single-project mode を default のままにする。

### Phase 3: Manual Multi-Project Operation

- `run-once`、`resume`、`describe-task`、`logs`、`clear-logs` など lifecycle command に explicit `--project` を許可する。
- registry に複数 project definition を登録できるようにする。
- write operation は引き続き explicit project selection を要求する。

### Phase 4: Agent Binding

- agent/session default project binding を追加する。
- policy に従って request-level explicit project override を許可する。
- agent request bundle と worker result に project key を記録する。

### Phase 5: Optional Cross-Project Convenience

- `status --all-projects` や read-only summary を追加する。
- multi-project scheduler supervision は project-scoped locking が安定してから検討する。

## Current Inventory Notes

静的調査では、以下が特に強い単一 project 前提として見つかっている。

- Go launcher の `runtime-instance.json` は package path、workspace root、Kanban、storage を1セットだけ持つ。
- `buildRuntimeRunOncePlan` は package/config/storage/Kanban/repo-source/log/agent workspace を単一 plan に集約している。
- Ruby 側の task/run repository は `task.ref` や `run.ref` を単独 key として扱う。
- agent job store と artifact store に project namespace がない。
- scheduler pid/log/command path が workspace root 配下の固定 path になっている。
- Kanban CLI adapter は単一 project / board / repo label map 前提で構築される。

このため、実装は agent binding から始めず、先に durable record と side-effect boundary に project key を通す。

## Open Questions

- registry file は既存 runtime instance file に対してどこに置くべきか。
- branch namespace は project key、runtime instance id、または両方のどれを使うべきか。
- project key rename を許可するか。
- multi-project mode で Kanban board display ref に project prefix を含めるべきか。
- `a2o-agent` が execution に project key を持ち回るための最小変更は何か。
- 外部 Kanbalone + 複数 board を推奨 topology にするべきか。

## Review Checklist

- project resolution 前に副作用が起きない。
- unqualified task ref が project boundary をまたがない。
- 既存 single-project command が有効なまま。
- project package schema が runtime registry config に侵食されない。
- agent binding は durable project context の上に乗る層であり、土台ではない。
- implementation phase が後の breaking redesign を要求しない。
