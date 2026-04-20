# A2O Overview

この文書は、A2O が何を実現し、利用者・project package・kanban・A2O Engine・a2o-agent・生成AI・Git repository がどうつながるかを説明する。

## A2O が実現すること

A2O は kanban task を起点に、AI による実装、検証、merge、evidence 記録までを一連の runtime flow として扱う。

利用者が用意するもの:

- product repository
- `project.yaml`
- AI 用 skill files
- verification / remediation commands
- kanban task

A2O が担当するもの:

- kanban task の pickup
- task の phase 管理
- workspace / branch / repo slot の準備
- `a2o-agent` への job 指示
- verification / merge の orchestration
- kanban comment、status、evidence の記録

`a2o-agent` が担当するもの:

- host または project dev-env 上で command を実行する
- product 固有 toolchain を使う
- configured executor を通じて生成AIを使う
- 結果を workspace / Git branch へ反映する

## 通常実行の流れ

```text
利用者が project package を作る
  ↓
利用者が kanban に task を作る
  ↓
A2O scheduler が runnable task を選ぶ
  ↓
A2O Engine が task / project.yaml / skill から job を組み立てる
  ↓
a2o-agent が executor command を実行する
  ↓
executor が生成AIと product toolchain を使って作業する
  ↓
a2o-agent が変更を Git branch / workspace に反映する
  ↓
A2O Engine が verification / merge / evidence 記録を進める
  ↓
kanban に status、comment、blocked reason、完了結果が残る
```

この流れを理解してから quickstart を読むと、各 command の意味が追いやすくなる。

## 登場要素の関係

`project.yaml` は A2O に「どの board を見るか」「どの repository を扱うか」「どの phase でどの command / skill を使うか」を教える。

AI 用 skill files は executor に渡す作業方針である。A2O Engine は skill を直接実行するのではなく、phase job の材料として扱う。

Kanban は作業 queue であり、利用者から見える状態管理の場所である。A2O Engine は kanban から task を取り出し、進捗や判断結果を kanban に返す。

`a2o-agent` は product 環境側の実行役である。A2O Engine は container 内で orchestration を担当し、product 固有 command は agent 側で動く。

Git repository は最終成果物の置き場である。A2O は branch namespace と merge phase を通じて、AI 実行結果を Git の変更として扱う。

## 読み進め方

最初は次の順で読む。

1. [10-quickstart.md](10-quickstart.md): 最小手順で起動する。
2. [20-project-package.md](20-project-package.md): 利用者が管理する入力を理解する。
3. [30-operating-runtime.md](30-operating-runtime.md): scheduler、agent、kanban、runtime image を運用する。
4. [40-troubleshooting.md](40-troubleshooting.md): blocked / failed 時にどこを見るかを確認する。

詳細な schema や内部互換名は reference として後から読む。
