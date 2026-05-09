# M4: Backtracking trap (PR #911 cycle 2)

このファイルは bash code block 内で `flow-state-update.sh create` literal が
**行頭から** 始まる場合、PR #911 cycle 2 で empirical 再現された backtracking trap
を再発させないことを実証する fixture。

経緯: 旧実装の `^[[:space:]]*[^[:space:]#].*flow-state-update\.sh create` 形式は、
literal が行頭から始まる行で `[^[:space:]#]` が先頭 `f` を消費した結果、
続く literal が行内に再発見できず silent miss する trap があった。
現実装は前置 not-match `!/^[[:space:]]*#/` を採用し、行頭出現有無に
影響を受けない。

期待挙動:
- `total=1` (行頭 create literal を正しく検出)
- `asymmetric=0` (5-arg 完備)
- `Symmetry-bound: actual=1` で pass

## Phase D: line-start create literal

```bash
flow-state-update.sh create \
  --phase "phaseD" --issue 1 --branch "test" \
  --pr 0 \
  --next "next"
```
