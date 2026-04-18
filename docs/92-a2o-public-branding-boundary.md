# A2O Public Branding Boundary

対象読者: A2O/A3 設計者 / release maintainer
文書種別: 設計メモ

この文書は、外向き product name を `A2O` とし、内部実装名を `A3` のまま維持する境界を定義する。`A2O` は Agentic AI Orchestrator の公開名であり、Googleability と利用者への説明しやすさを優先する。

## 方針

- Public brand: `A2O`
- Public command: `a2o`
- Public image: `ghcr.io/wamukat/a2o-engine:latest`
- Public agent binary: `a2o-agent`
- Internal engine name: `A3`
- Internal command / module / env / legacy state: `a3`, `A3_*`, `.a3`, `a3-runtime`

## Rename しないもの

現行 release では、次は rename しない。

- legacy `.a3/runtime-instance.json` reader fallback
- `A3_*` environment variables
- Ruby module / Go package / internal class / internal file path
- runtime storage schema / artifact schema / job schema
- 過去の internal evidence に含まれる legacy `a3-agent` identifier

これらを rename すると state migration と既存 evidence の読み替えが必要になり、release candidate の安定性を落とす。外向き alias と packaging で吸収する。

## Public Alias

container image には `a3` と `a2o` の両方を置く。`a2o` は public entrypoint、`a3` は internal / compatibility entrypoint である。

host install は public launcher `a2o` を正として export し、compatibility alias `a3` も同時に export する。platform binary も `a2o-<os>-<arch>` と `a3-<os>-<arch>` を同梱する。

agent install は public path では `a2o-agent` を使う。binary の中身は existing `a3-agent` と同一であり、control plane protocol と artifact schema は変えない。compatibility が必要な runtime では `a3-agent` path も引き続き使える。

## Documentation Rule

利用者向け docs / quickstart / release note では `A2O` / `a2o` / `a2o-agent` を使う。内部設計、実装詳細、既存 evidence、既存 runtime state を説明する場合だけ `A3` を使い、近傍で internal engine name であることを明示する。

## Follow-up

- public docs に残る `a3` command 例は、internal / compatibility 文脈かどうかを棚卸しし、利用者向けは `a2o` に寄せる。
- 将来 `.a3` / `A3_*` を rename する場合は、別 release の state migration として扱う。
