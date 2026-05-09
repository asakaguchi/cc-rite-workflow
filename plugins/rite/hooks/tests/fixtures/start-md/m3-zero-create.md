# M3: Zero create invocations (Issue #908 finding 3)

このファイルは bash code block 内に `flow-state-update.sh create` 呼び出しが
**1 件も存在しない** 場合、`Symmetry-bound: actual >= 1` が fail することを
実証する fixture (regression 検出能力 = dead code 検出のための下限ガード)。

期待挙動:
- `total=0` (create 呼び出しなし)
- `asymmetric=0`
- `Symmetry-bound: actual=0` で fail (下限割れ → 全削除 regression 検出)

## Phase C: bash blocks without create

このセクションには bash code block が存在するが、いずれの block にも
`flow-state-update.sh create` literal を **一切含まない** ことに注意。
quoted-string 内 (`echo "..."` 等) であっても awk は shell quote を解釈しない
ため、literal が含まれていれば quote の内外を問わず count されてしまう。
これを回避するため literal 出現自体を含まないシンプルな command のみを
記述する。

```bash
echo "no creation invocation here"
```

```bash
gh issue view 1 --json body
```
