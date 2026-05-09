# M5: Inline shell comment (Issue #912 finding 1)

このファイルは bash code block 内で **行内 inline `#` shell comment** に
`flow-state-update.sh create` 言及がある場合、Symmetry pipeline が
inline comment を strip してから判定し false positive を排除することを
実証する fixture。

経緯: PR #913 (Issue #912 finding 1) で `sub(/[[:space:]]+#.*$/, "", line)`
を awk action に追加し、whitespace-preceded inline shell comment を
strip してから literal 判定する形式に拡張。

期待挙動:
- `total=0` (inline comment 内 literal 言及は false positive として排除される)
- `asymmetric=0`
- `Symmetry-bound: actual=0` で fail (下限割れ)

## Phase E: inline comment block

```bash
echo "running" # legacy reference: flow-state-update.sh create --phase X --issue 1 --branch y --pr 0 --next z
gh issue view 1
```
