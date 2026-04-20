# Runtime Naming Boundary（runtime 命名境界）

A2O の正式名称は Agentic AI Orchestrator であり、公開 product 名である。A3 は内部互換名であり、実装 code path、state path、Engine CLI surface に現れる場合がある。

## 公開名

利用者向け docs と commands では、次の名前を使う。

- `A2O`
- `a2o`
- `a2o-agent`
- `share/a2o`
- `.work/a2o/agent`
- `refs/heads/a2o/...`
- `reference-products`

## 内部互換名

次の名前は実装詳細として残ってよい。

- `A3`
- `a3`
- `bin/a3`
- `.a3`
- `A3_*` environment variables（環境変数）
- compatibility `refs/heads/a3/...`（内部互換 refs）

通常の setup docs で、利用者にこれらの名前を author させてはならない。diagnostics や内部実装 docs に出す場合は、互換 surface であることを明記する。

## 命名 rule

- 新しい公開 docs では A2O 名を使う。
- 新しい project package では A2O 名を使う。
- 新しい CLI affordance は `a2o` を優先する。
- 内部 Ruby Engine API は、公開 user surface に出ない範囲で A3 名を保持してよい。
- 互換 alias を documented primary path にしてはならない。

## 利用者向け runtime

利用者向け runtime execution は `a2o runtime run-once`、`a2o runtime loop`、または `a2o runtime start` を使う。内部 Engine CLI の例は通常の利用者向け setup docs から除外する。
