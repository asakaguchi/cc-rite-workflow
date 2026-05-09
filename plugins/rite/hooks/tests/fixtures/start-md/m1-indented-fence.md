# M1: Indented bash fence (Issue #908 finding 1)

このファイルは `start-md-charter.test.sh` の Symmetry pipeline が
indented bash code fence (リスト項目内の 4-space indent fence 等) を
正しく検出することを実証する fixture。

期待挙動:
- `total=1` (indented fence 内の create 1 件を検出)
- `asymmetric=0` (5-arg 完備)
- `Symmetry-bound: actual=1` で pass

## Phase A: indented fence under list

1. リスト項目内に bash code block を埋め込むケース:

   ```bash
   bash {plugin_root}/hooks/flow-state-update.sh create \
     --phase "phaseA" --issue 1 --branch "test" \
     --pr 0 \
     --next "next action"
   ```

   このブロックは行頭に 3 つ space があるため、`^```bash` (anchored) では
   検出されず、`^[[:space:]]*```bash` (PR #911 finding 1 fix) が必要。
