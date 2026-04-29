# Implementation Rework Prompt

review finding を最優先の入力として扱い、各 finding に対して原因、修正内容、再検証を対応づける。finding と無関係な改善やリファクタリングは追加しない。

修正後は、指摘を再発させない focused test または検証手順を実行する。対応できない finding がある場合は、理由と次に必要な判断を明確にする。

