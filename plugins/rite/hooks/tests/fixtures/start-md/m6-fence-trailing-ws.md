# M6: Fence trailing whitespace (Issue #912 finding 2)

このファイルは bash code fence 終端 (` ``` `) に **trailing whitespace** が
含まれる場合 (CommonMark 仕様上は valid)、Symmetry pipeline が fence を
正しく終端認識し block を抽出することを実証する fixture。

経緯: PR #913 (Issue #912 finding 2) で fence 終端 regex を
`^[[:space:]]*` + 3 backticks + `[[:space:]]*$` に拡張し、trailing whitespace
を許容。fence 開始側 (`^[[:space:]]*` + 3 backticks + `bash`) は info string
直後の空白が code language の一部にならないため拡張不要。

期待挙動:
- `total=1` (fence trailing whitespace でも block 正常終端、create 1 件検出)
- `asymmetric=0` (5-arg 完備)
- `Symmetry-bound: actual=1` で pass

## Phase F: fence with trailing whitespace

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phaseF" --issue 1 --branch "test" \
  --pr 0 \
  --next "next"
``` 
