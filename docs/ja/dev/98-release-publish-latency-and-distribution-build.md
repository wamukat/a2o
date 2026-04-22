# Release Publish Latency And Distribution Build

この文書は、A2O の release publish が遅い理由と、現在の install surface を壊さずに改善するための検討結果を記録する。

## 現状観測

直近の runtime image publish では、単一の `Build runtime image` ステップが支配的なボトルネックになっている。

- Run `24773195829`: `Build runtime image` は約 `14m38s`
- Run `24778382881`: `Build runtime image` は約 `18m11s`

ローカルの Docker build でも同じ傾向が確認できた。

- `agent-builder` は約 `215s`
- runtime base dependency install と bundler setup は概ね `80s + 11s`

したがって、publish の遅さは偶発的な CI 遅延ではなく、構造的なものと判断できる。

## なぜ遅いのか

現在の runtime image Dockerfile は、agent package の組み立てまで内包している。

1. publish workflow は multi-arch runtime image を build する
   - `linux/amd64`
   - `linux/arm64`
2. Dockerfile の `agent-builder` stage で `agent-go/scripts/build-release.sh` を実行する
3. この script は現在、4 つの host target を build する
   - `darwin/amd64`
   - `darwin/arm64`
   - `linux/amd64`
   - `linux/arm64`
4. 生成した agent package directory を runtime image の `/opt/a2o/agents` にコピーする

つまり、現在の runtime image publish 1 回には次が全部入っている。

- 2 つの container platform 向け Linux runtime image build
- 4 つの host target 向け agent distribution build
- Ruby dependency install
- Debian package install

本来は別責務だが、今は 1 つの publish path に結合されている。

## 追加 target が存在する理由

余分に見える host target build には意味がある。

現在の user-facing install flow は、runtime image を packaged host artifact の供給元として使っている。

- `a2o host install`
- `a2o agent install`
- `a3 agent package list|verify|export`

runtime image には `/opt/a2o/agents/release-manifest.jsonl` と target 別 archive が含まれ、install/export command はその package store を読む。

そのため、runtime image から単純に `darwin` package を外すと、現在の macOS host install flow は壊れる。

## 境界上の問題

主因は base image そのものではない。主因は境界が混ざっていることにある。

- runtime image publish
- host/agent distribution build
- install package の source of truth

が、いまは一体として扱われている。

この構成は user experience を単純にする一方で、release publish を遅くしている。

## 改善案

### Option A: 小さな最適化だけ行う

現在の packaging model を維持し、Dockerfile / cache の挙動だけを改善する。

候補:

- apt / bundler の churn を減らす
- layer reuse を改善する
- 不要な context invalidation を減らす

期待効果:

- 限定的
- 漸進改善に留まる可能性が高い

リスク:

- 低い

### Option B: distribution assembly を runtime image publish から分離する

CLI surface は維持したまま、host agent package assembly を runtime image Docker build の外へ出す。

候補:

- host agent package は別 workflow / job で build/publish する
- manifest と archive は release asset か別 package surface に publish する
- 利用者から見た `a2o agent install` / `a2o host install` は維持する
- install/export の実装だけ、新しい distribution source を参照するように変える

期待効果:

- 大きい
- 主要な構造改善ポイント

リスク:

- 中程度
- package source と install path の設計変更が必要

この option を実装へ進める前に、設計判断を次の単位に分解する必要がある。

1. package publication surface
   - host agent manifest / archive をどこへ publish するか
   - version 付き artifact をどう address するか
   - checksum / integrity verification をどう運ぶか
2. install-time resolution / fallback policy
   - `a2o agent install` / `a2o host install` が対象 package をどう見つけるか
   - offline 時や primary source 不達時にどう振る舞うか
   - 移行中に runtime image を fallback source として残すか
3. runtime-image compatibility boundary
   - 移行中にどの host artifact を image に残すか
   - いつ embedded target を減らしてよいか
   - 現在の macOS install flow 互換をどう保つか

### Option C: 分離後に runtime image の同梱物を減らす

install flow が runtime image に全面依存しなくなった後で、runtime image に載せる host package 内容を減らす。

候補:

- runtime image には Linux 用のみ残す
- あるいは host package archive 自体を載せない

期待効果:

- 高い
- ただし Option B の後で行うべき

リスク:

- install path 分離前に実施すると高い

## 推奨順序

1. package publication surface を決める
2. install-time resolution / fallback policy を決める
3. migration 中の runtime-image compatibility boundary を決める
4. CLI surface を維持したまま distribution separation を実装する
5. install/export 実装を新しい distribution source に切り替える
6. runtime image に埋め込む host package 内容を減らす
7. その上で Dockerfile / cache の小改善を重ねる

## 改善幅の見込み

現状 timing から見て:

- Dockerfile のみの小改善: 効果は限定的
- distribution の構造分離: 最も効く
- 境界整理まで含めた本格対応: 大きな短縮余地がある

現在の十数分級 publish を、明確に短いレンジへ下げるには、image layer の微調整よりも構造改善が必要である。

## Follow-up Breakdown

follow-up ticket は次のように分担する。

- `A2O#159`: host agent package publication surface の定義
- `A2O#158`: install-time resolution / fallback policy の定義
- `A2O#157`: runtime image と external package の compatibility contract 定義
- `A2O#155`: `A2O#157`、`A2O#158`、`A2O#159` の後続として distribution separation を実装
- `A2O#156`: 構造改善後の second-order Dockerfile / cache 最適化
