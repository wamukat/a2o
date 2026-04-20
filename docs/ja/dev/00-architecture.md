# A2O Architecture

この文書は、A2O Engine が kanban、project package、a2o-agent、生成AI、Git repository をどうつなぎ、task automation をどう成立させるかを説明する。

設計資料の入口として、まず全体の流れを押さえ、その後で domain model、workspace、agent gateway、kanban adapter などの詳細へ進む。

## A2O が実現する runtime flow

A2O は「kanban task を AI 実行可能な job に変換し、検証と merge までを traceable に進める」runtime である。

1. 利用者が project package と kanban task を用意する。
2. Scheduler が runnable task を選ぶ。
3. Engine が task、`project.yaml`、skill、repo slot から phase job を作る。
4. `a2o-agent` が host / dev-env で executor command を実行する。
5. Executor が生成AIと product toolchain を使って変更を作る。
6. Engine が verification、merge、evidence、kanban status を管理する。

この flow を支えるために、domain model は task lifecycle を、workspace model は source と branch を、agent gateway は外部 command 実行を、kanban adapter は visible task state を担当する。

## システム概観

```mermaid
flowchart LR
  User@{ shape: stadium, label: "利用者" }
  Agent@{ shape: stadium, label: "a2o-agent" }
  AI@{ shape: cloud, label: "生成AI" }

  subgraph Inputs["利用者が管理する入力"]
    ProjectInputs@{ shape: docs, label: "プロジェクト設定 / AI 用スキル群" }
  end

  subgraph Engine["A2O Engine"]
    Kanban@{ shape: cyl, label: "カンバン\ntask queue" }
    Scheduler@{ shape: rounded, label: "scheduler\n実行可能な task を選択" }
    Prepare@{ shape: rounded, label: "Job を準備して指示する\ntask / config / skills から生成" }
    Report@{ shape: rounded, label: "結果を記録\nkanban comments / status" }
  end

  Repository@{ shape: cyl, label: "Git repository" }

  User -->|"task を作る"| Kanban
  User -.->|"作成する"| ProjectInputs
  Kanban --> Scheduler
  Scheduler --> Prepare
  ProjectInputs --> Prepare
  Prepare --> Agent
  Agent -->|"Job の実行を指示"| AI
  AI -->|"Job result"| Agent
  Agent -->|"変更を反映"| Repository
  Agent --> Report
  Report --> Kanban
```

通常利用では、利用者は kanban task とプロジェクト入力を作成する。常駐 scheduler は Engine が管理する kanban state から実行可能な task を選ぶ。Engine は task、プロジェクト設定、AI 用スキル群を組み合わせて AI 実行 job を用意する。`a2o-agent` は host または project dev-env で job を実行し、生成AIに job の実行を指示し、結果を Git repository に反映する。Engine は task status、comments、evidence を kanban に記録する。

## 責務境界

- A2O Engine: task lifecycle、scheduler、phase orchestration、kanban adapter、evidence、merge orchestration。
- Project package: project 固有の repo slots、labels、skills、executor commands、verification / remediation commands。
- a2o-agent: product 環境での command execution、workspace materialization、artifact publication。
- 生成AI: executor command から指示される実装・レビュー補助。
- Git repository: AI 実行結果と merge 結果を保持する成果物。

## 設計資料一覧

### 0. 利用者導線

- [../user/00-overview.md](../user/00-overview.md)
- [../user/10-quickstart.md](../user/10-quickstart.md)

A2O の全体像と導入手順を扱う。

### 1. 実装規律

- [10-engineering-rulebook.md](10-engineering-rulebook.md)

immutable、TDD、リファクタリング、必要修正から逃げないことを固定する。

### 2. 用語と bounded context

- [20-bounded-context-and-language.md](20-bounded-context-and-language.md)

task kind、phase、workspace、repo slot、evidence などの用語を固定する。

### 3. core domain model

- [30-core-domain-model.md](30-core-domain-model.md)

aggregate / entity / value object と状態遷移を扱う。

### 4. workspace / repo-slot / lifecycle

- [40-workspace-and-repo-slot-model.md](40-workspace-and-repo-slot-model.md)

fixed repo slot、同期方針、freshness、retention、GC、merge workspace を扱う。

### 5. Project Surface

- [50-project-surface.md](50-project-surface.md)
- [55-project-script-contract.md](55-project-script-contract.md)
- [../user/90-project-package-schema.md](../user/90-project-package-schema.md)
- [80-runtime-extension-boundary.md](80-runtime-extension-boundary.md)

project package schema、project script contract、repo slot、verification、bootstrap hook の境界を扱う。

### 6. evidence / rerun / blocked diagnosis

- [60-evidence-and-rerun-diagnosis.md](60-evidence-and-rerun-diagnosis.md)

review / merge / rerun / blocked 調査の再現性を支える内部 evidence を扱う。

### 7. runtime distribution

- [../user/30-operating-runtime.md](../user/30-operating-runtime.md)
- [70-agent-worker-gateway-design.md](70-agent-worker-gateway-design.md)
- [../user/95-runtime-naming-boundary.md](../user/95-runtime-naming-boundary.md)

Docker runtime image、host launcher、bundled kanban service、agent gateway、内部互換名の境界を扱う。

### 8. reference validation

- [90-reference-product-suite.md](90-reference-product-suite.md)

core validation で使う sample product と validation boundary を扱う。

### 9. current release surface

- [../user/80-current-release-surface.md](../user/80-current-release-surface.md)

A2O 0.5.5 の supported public surface と validation boundary を扱う。

### 10. kanban adapter boundary

- [95-kanban-adapter-boundary.md](95-kanban-adapter-boundary.md)

kanban command contract と adapter boundary を扱う。
