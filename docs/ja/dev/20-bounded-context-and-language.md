# A2O Bounded Contexts And Language

この文書は、A2O で使う vocabulary と bounded context を定義する。Domain、workspace、evidence、implementation document はこの用語を使う。

## Runtime flow 上の位置づけ

この文書は、kanban task が scheduler に pickup され、Engine が phase job を作り、a2o-agent が job を実行し、evidence と kanban state が更新されるまでの言葉を揃える。詳細文書で出てくる Task、Run、Phase、Workspace、Project Package、Operator Inspection は、この bounded context に沿って読む。

## Design Stance

A2O は code structure の都合ではなく domain meaning によって概念を命名する。

- 先に意味を定義し、その後で class / module / file 名を合わせる。
- Phase-specific rescue branch を domain language に入れない。
- Public vocabulary は A2O 名を使う。A3 は internal compatibility name として必要な場合だけ残る。

## Context Map

### Task Execution Context

Owns:

- task kind
- phase
- run
- terminal outcome
- rerun eligibility

この context は task が lifecycle のどこにいるか、次に何が起きるかを決める。

### Workspace Context

Owns:

- workspace kind
- repo slot
- source descriptor
- artifact owner
- freshness and cleanup policy

この context は phase が使う source tree と、work の materialization 方法を決める。

### Project Package Context

Owns:

- package identity
- kanban board name
- repo slots and labels
- agent prerequisites
- phase commands and skills
- verification and remediation commands
- merge defaults

この context は product-owned configuration surface である。

### Operator Inspection Context

Owns:

- evidence summary
- blocked-run diagnosis
- watch summary
- describe-task output
- runtime status and doctor output

この context は何が起きたか、operator が次に何をすべきかを説明する。

## Core Terms

### Task

Kanban から取り込む、または parent-child flow の一部として作成される work unit。

### Task Kind

- `single`: standalone task。
- `child`: parent scope の一部を変更する task。
- `parent`: child aggregation、parent review、parent verification、live merge を所有する integration task。

### Phase

現在処理中の execution step。Public project package は次を使う。

- `implementation`
- `review`
- `parent_review`
- `verification`
- `remediation`
- `merge`

### Run

1 task phase を実行する 1 attempt。Run は phase、workspace、source descriptor、outcome、evidence、blocked details を記録する。

### Terminal Outcome

Run の最終結果。例: success、blocked、failed verification、merge conflict、executor failure。

### Repo Slot

Repository に対する stable project package alias。例: `app`、`repo_alpha`、`repo_beta`。Runtime behavior は hard-coded product path ではなく repo slot を使う。

### Workspace Kind

- `ticket_workspace`: implementation work に使う。
- `runtime_workspace`: review、verification、merge に使う。

### Evidence

Transient log に依存せず、operator が何が起きたかを inspect できる structured records and artifacts。

### Source Descriptor

Run が使った code を定義する source ref と workspace kind。

### Artifact Owner

Evidence snapshot を所有する task または parent task。

## Public Naming

Users should see A2O names:

- `A2O`
- `a2o`
- `a2o-agent`
- `.work/a2o`
- `refs/heads/a2o/...`

Internal compatibility names は、必要な場合だけ implementation details と diagnostics に残してよい。
