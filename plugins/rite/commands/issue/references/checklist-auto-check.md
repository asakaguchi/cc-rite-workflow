# Checklist Auto-Check — Phase 5.2.1 + 5.2.1.1 SoT

> **Source of Truth**: 本ファイルは `/rite:issue:start` Phase 5.2.1 (Checklist Confirmation) および Phase 5.2.1.1 (Auto-Check Evaluation) の **bash literal + 評価ロジック の SoT** である。`start.md` 本体の Phase 5.2.1 / 5.2.1.1 は本ファイルへ semantic 参照する anchor stub のみ保持する。
>
> **抽出経緯**: `start.md` Phase 5.2.1 + 5.2.1.1 は ~100 行で、Issue body checklist の grep 確認 + auto-check evaluation + uncertain handling + re-check の 4 layer logic を 1 reference に集約することで、本体の認知負荷を下げる。Issue #901 (PR E — #896 親 Issue) で抽出。
>
> **caller**: `start.md` Phase 5.2.1 (唯一の caller、`/rite:lint` returns 直後に呼び出される)。

## Phase 5.2.1: Checklist Confirmation

**Owner**: `/rite:issue:start` after `/rite:lint` returns. **Condition**: Execute only if checklist retained in Phase 3.6. **Purpose**: Block PR until all items complete.

Use `grep -E` (not `-P`). Pattern per [gh-cli-patterns.md](../../../references/gh-cli-patterns.md#safe-checklist-operation-patterns).

```bash
issue_body=$(gh issue view {issue_number} --json body --jq '.body')
[ -z "$issue_body" ] && echo "ERROR: Issue body の取得に失敗" >&2 && exit 1
echo "$issue_body" | grep -E '^- \[[ xX]\] ' | grep -v -E '^- \[[ xX]\] #[0-9]+' || true
echo "$issue_body" | grep -E '^- \[[ xX]\] ' | grep -v -E '^- \[[ xX]\] #[0-9]+' | grep -c '^- \[ \] ' || true
```

**Determine**: `grep -c` output `0`→all complete→5.3. `≥1`→incomplete→proceed to 5.2.1.1 (auto-check). Empty body→retry 5.1. **Mandatory**, cannot skip.

## Phase 5.2.1.1: Auto-Check Evaluation

When incomplete checklist items are detected, evaluate each item's fulfillment status based on the current implementation state before returning to Phase 5.1.

**Purpose**: Prevent infinite loops where implementation is complete but Definition of Done checklist items remain unchecked because no process updates them to `- [x]`.

### Evaluation procedure

**Step 0: Mass-residual warning (≥5 incomplete items)** — Before evaluation, count incomplete items (excluding parent-child Tasklist `- [ ] #XX` entries) and surface a Root Cause investigation prompt when the count meets the mass-residual threshold (5 件以上):

```bash
issue_body=$(gh issue view {issue_number} --json body --jq '.body')
[ -z "$issue_body" ] && echo "WARNING: Step 0 Issue body 取得失敗 — mass-residual 検出を skip" >&2 && incomplete_count=0
incomplete_count=${incomplete_count:-$(echo "$issue_body" | grep -E '^- \[[ xX]\] ' | grep -v -E '^- \[[ xX]\] #[0-9]+' | grep -c '^- \[ \] ' || true)}
echo "incomplete_count=$incomplete_count"
if [ "${incomplete_count:-0}" -ge 5 ]; then
  echo "⚠️ Phase 5.2.1.1 Step 0: Issue 本文に 5 件以上の未完了チェックリスト項目が残存しています (${incomplete_count} 件)。"
  echo "   Root Cause として以下が考えられます:"
  echo "   - Phase 5.1.1.1 (implement.md) の per-task checklist 更新が trigger されていない"
  echo "   - 実装が Definition of Done を完全充足していない"
  echo "   - チェックリスト項目テキストと実装内容の対応付けが Auto-Check で unreliable と判定された"
  echo "   ACTION REQUIRED: 下記 AskUserQuestion で Root Cause を選択してから Step 1 に進むこと"
fi
```

**MUST**: `incomplete_count >= 5` の場合、Step 1 (Collect evidence) に進む前に **必ず以下の `AskUserQuestion` を発火させる**。bash 出力 + warning だけで Step 1 へ直行することは禁止 (silent fall-through 防止)。`{incomplete_count}` placeholder は上記 bash block の `incomplete_count` 出力値を substitute する:

```
警告: Issue 本文に 5 件以上の未完了チェックリスト項目が残存しています ({incomplete_count} 件)

このまま Auto-Check Evaluation を続行すると一括判定で誤検知のリスクがあります。
Root Cause を調査しますか?

オプション:
- Root Cause を調査してから Auto-Check (推奨): Phase 5.1 に戻り per-task 更新漏れの根本原因を特定してから再評価
- このまま Auto-Check Evaluation を続行: 既存パスで一括評価 (実装が確実に完了している場合)
- 手動でチェックリスト確認: workflow を中断しユーザーが Issue body を手動更新
```

「Root Cause 調査」→ Phase 5.1 に戻る (`implement.md` Phase 5.1.1.1 を per-task で再実行)。「そのまま Auto-Check」→ Step 1 へ続行。「手動確認」→ workflow 中断、ユーザー手動更新後 `/rite:issue:start {N}` で再開を案内。`incomplete_count < 5` の場合は本 Step を skip し Step 1 へ直接遷移する。

1. **Collect evidence**: Use `git diff origin/{base_branch}...HEAD --name-only` and `git log --oneline origin/{base_branch}...HEAD` to understand what was implemented.

2. **Evaluate each incomplete item**: For each `- [ ]` item, assess whether the item is satisfied based on the implementation evidence:

   | Assessment | Criteria | Action |
   |-----------|----------|--------|
   | **Satisfied** | Implementation evidence clearly fulfills the item | Mark as `- [x]` |
   | **Not satisfied** | No evidence of fulfillment, or clearly incomplete | Keep as `- [ ]` |
   | **Uncertain** | Cannot confidently determine | Present to user via `AskUserQuestion` |

3. **Update Issue body**: If any items are newly marked as satisfied, update the Issue body via `gh issue edit`:

   Follow the "Checkbox Update" pattern in [gh-cli-patterns.md](../../../references/gh-cli-patterns.md#safe-checklist-operation-patterns). Use Read+Write tools for safe `- [ ]` → `- [x]` replacement (do NOT use `sed`).

   ```bash
   # Step 1: Retrieve current body and validate
   tmpfile_read=$(mktemp)
   tmpfile_write=$(mktemp)
   trap 'rm -f "$tmpfile_read" "$tmpfile_write"' EXIT
   gh issue view {issue_number} --json body --jq '.body' > "$tmpfile_read"

   if [ ! -s "$tmpfile_read" ]; then
     echo "ERROR: Issue body の取得に失敗" >&2
     exit 1
   fi

   # Output paths for subsequent Read/Write tool calls
   echo "tmpfile_read=$tmpfile_read"
   echo "tmpfile_write=$tmpfile_write"
   ```

   Then use the Read tool to read `$tmpfile_read` (the path output above), apply `- [ ]` → `- [x]` replacements for satisfied items using the Write tool to `$tmpfile_write`, and apply:

   **Note**: Shell variables do not carry over between Bash tool calls. Use the literal paths output by `echo "tmpfile_read=..."` in Step 1 directly in the command below.

   ```bash
   # Replace with actual paths from Step 1 output (e.g., /tmp/tmp.XXXXXXXXXX)
   tmpfile_write="/tmp/tmp.XXXXXXXXXX"  # ← Step 1 の出力値に置換

   if [ ! -s "$tmpfile_write" ]; then
     echo "ERROR: Updated content is empty" >&2
     exit 1
   fi

   gh issue edit {issue_number} --body-file "$tmpfile_write"
   ```

4. **Re-check**: After updating, re-run the checklist check:

   ```bash
   issue_body=$(gh issue view {issue_number} --json body --jq '.body')
   [ -z "$issue_body" ] && echo "ERROR: Issue body の取得に失敗" >&2 && exit 1
   echo "$issue_body" | grep -E '^- \[[ xX]\] ' | grep -v -E '^- \[[ xX]\] #[0-9]+' | grep -c '^- \[ \] ' || true
   ```

   - `0` (all complete) → Proceed to Phase 5.3
   - `≥1` (still incomplete) → Display remaining incomplete items and return to Phase 5.1
   - Empty body → retry Phase 5.1

### User confirmation for uncertain items

When items are assessed as "Uncertain", use `AskUserQuestion`:

```
以下のチェックリスト項目の充足状態を確認してください:

- [ ] {item_text}

オプション:
- 充足済みとしてチェック（推奨）: この項目を完了とマークします
- 未充足: Phase 5.1 に戻って対応します
```

### Constraints

- Already checked items (`- [x]`) are never modified (AC-3 non-regression)
- Issue reference items (`- [ ] #XX`) are excluded from evaluation (parent-child tracking)
- Auto-check is executed **at most once per 5.2.1 invocation** to prevent evaluation loops

## 関連

- [`../../../references/gh-cli-patterns.md`](../../../references/gh-cli-patterns.md#safe-checklist-operation-patterns) — Safe Checklist Operation Patterns / Checkbox Update pattern
