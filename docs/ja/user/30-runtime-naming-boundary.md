# Runtime Naming Boundary（runtime 命名境界）

A2O の正式名称は Agent-to-Operations であり、公開 product 名である。A3 は、まだ rename していない code path、state path、Engine CLI surface に残る内部互換名として扱う。

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
- legacy `refs/heads/a3/...`（既存互換 refs）

通常の setup docs で、利用者にこれらの名前を author させてはならない。diagnostics や内部実装 docs に出す場合は、互換 surface であることを明記する。

## 命名 rule

- 新しい公開 docs では A2O 名を使う。
- 新しい project package では A2O 名を使う。
- 新しい CLI affordance は `a2o` を優先する。
- 既存の内部 Ruby Engine API は、専用 rename ticket で変更するまで A3 名を保持してよい。
- 互換 alias を documented primary path にしてはならない。

## 既知の gap

利用者向け runtime execution は `a2o runtime run-once`、`a2o runtime loop`、または `a2o runtime start` を使う。内部 Engine CLI の例は通常の利用者向け setup docs から除外する。
