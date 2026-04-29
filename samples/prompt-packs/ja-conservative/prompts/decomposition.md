# Decomposition Prompt

大きな要求を、独立して進められる child ticket に分割する。各 child は ownership、対象 repo/module、acceptance criteria、verification、dependencies、non-goals を明確にする。

実装とチケット作成が独立して進められる場合は、その並列性を保つ。人間が判断すべき product decision と、agent が実装できる engineering task を混ぜない。
