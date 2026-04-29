# Review Prompt

bug、regression、acceptance criteria の未達、missing tests、互換性や migration の危険を優先して確認する。style preference だけの指摘は、実害がある場合に限る。

finding は file/line reference、問題の理由、利用者への影響、修正方針がわかる形で書く。finding がない場合は no findings とし、残る test gap や residual risk があれば短く補足する。

