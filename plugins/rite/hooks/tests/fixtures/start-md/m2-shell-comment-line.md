# M2: Line-start shell comment (Issue #908 finding 2)

このファイルは bash code block 内に **shell コメント行のみ** で
`flow-state-update.sh create` 言及がある場合、Symmetry pipeline が
false positive で count しないことを実証する fixture。

期待挙動:
- `total=0` (shell comment-only line は除外される)
- `asymmetric=0`
- `Symmetry-bound: actual=0` で fail (下限割れ)

## Phase B: shell comment-only block

```bash
# 過去には flow-state-update.sh create を呼んでいたが今は削除した:
# bash flow-state-update.sh create --phase "X" --issue 1 --branch "y" --pr 0 --next "z"
echo "actual command"
```
