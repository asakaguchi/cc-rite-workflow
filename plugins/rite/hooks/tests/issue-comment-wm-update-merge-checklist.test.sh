#!/bin/bash
# issue-comment-wm-update-merge-checklist.test.sh
#
# Pins the `merge-checklist` transform (archive-procedures
# §3.5.2 progress-merge delegation). Verifies the verbatim-fidelity contract
# ported from the original inline Python block:
#   - full-body exact-line dedup (idempotency / partial dedup)
#   - insertion at the end of the named section (before next `### ` / at EOF)
#   - section-absent → body unchanged, items dropped
#   - trailing-newline state of the input preserved
#
# The transform is a pure stdin→stdout text op (no gh API), so it is driven
# end-to-end here. run-tests.sh auto-discovers this file via the *.test.sh glob.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="$SCRIPT_DIR/../issue-comment-wm-update.py"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required but not installed" >&2
  exit 1
fi

# The standard 3 completion items the §3.5.2 caller merges into ### 進捗.
items_file="$TEST_DIR/items.txt"
printf '%s\n' "- [x] レビュー完了" "- [x] マージ完了" "- [x] クリーンアップ完了" > "$items_file"

echo "=== issue-comment-wm-update.py merge-checklist tests ==="
echo ""

# ─── TC-001: new items appended at end of section, existing preserved ────
echo "TC-001: append new items at end of 進捗 (before next ###), existing kept"
body1=$'## 📜 rite 作業メモリ\n\n### 進捗\n- [x] 実装完了\n- [x] PR マージ済み\n\n### 完了情報\n- **PR**: #1\n'
printf '%s' "$body1" | python3 "$PY" merge-checklist --section 進捗 --content-file "$items_file" > "$TEST_DIR/out1"

if grep -qxF -- "- [x] 実装完了" "$TEST_DIR/out1" && grep -qxF -- "- [x] PR マージ済み" "$TEST_DIR/out1"; then
  pass "TC-001a: existing 進捗 items preserved"
else
  fail "TC-001a: existing items lost"
fi

if grep -qxF -- "- [x] レビュー完了" "$TEST_DIR/out1" \
   && grep -qxF -- "- [x] マージ完了" "$TEST_DIR/out1" \
   && grep -qxF -- "- [x] クリーンアップ完了" "$TEST_DIR/out1"; then
  pass "TC-001b: 3 new completion items appended"
else
  fail "TC-001b: new items missing"
fi

item_ln=$(grep -nF -- "- [x] クリーンアップ完了" "$TEST_DIR/out1" | head -1 | cut -d: -f1 || true)
done_ln=$(grep -nF -- "### 完了情報" "$TEST_DIR/out1" | head -1 | cut -d: -f1 || true)
if [ -n "$item_ln" ] && [ -n "$done_ln" ] && [ "$item_ln" -lt "$done_ln" ]; then
  pass "TC-001c: new items inserted within 進捗 (before ### 完了情報)"
else
  fail "TC-001c: insertion position wrong (item=$item_ln, 完了情報=$done_ln)"
fi
echo ""

# ─── TC-002: idempotent — re-run is byte-identical ───────────────────────
echo "TC-002: idempotent re-run (byte-identical, no duplicates)"
python3 "$PY" merge-checklist --section 進捗 --content-file "$items_file" < "$TEST_DIR/out1" > "$TEST_DIR/out2"
dup_count=$(grep -cxF -- "- [x] レビュー完了" "$TEST_DIR/out2" || true)
if cmp -s "$TEST_DIR/out1" "$TEST_DIR/out2" && [ "$dup_count" = "1" ]; then
  pass "TC-002: re-run is a no-op (byte-identical, レビュー完了 count=1)"
else
  fail "TC-002: not idempotent (cmp differs or count=$dup_count)"
fi
echo ""

# ─── TC-003: partial dedup — only missing items appended ─────────────────
echo "TC-003: partial dedup (already-present item skipped)"
body3=$'## 📜 rite 作業メモリ\n\n### 進捗\n- [x] 実装完了\n- [x] レビュー完了\n\n### 次\n'
printf '%s' "$body3" | python3 "$PY" merge-checklist --section 進捗 --content-file "$items_file" > "$TEST_DIR/out3"
rev_count=$(grep -cxF -- "- [x] レビュー完了" "$TEST_DIR/out3" || true)
if [ "$rev_count" = "1" ] \
   && grep -qxF -- "- [x] マージ完了" "$TEST_DIR/out3" \
   && grep -qxF -- "- [x] クリーンアップ完了" "$TEST_DIR/out3"; then
  pass "TC-003: existing レビュー完了 not duplicated; other 2 appended"
else
  fail "TC-003: partial dedup wrong (レビュー完了 count=$rev_count)"
fi
echo ""

# ─── TC-004: section absent → body unchanged, items dropped ──────────────
echo "TC-004: section absent → no-op (verbatim with original block)"
body4=$'## 📜 rite 作業メモリ\n\n### 完了情報\n- **PR**: #1\n'
printf '%s' "$body4" > "$TEST_DIR/body4"
python3 "$PY" merge-checklist --section 進捗 --content-file "$items_file" < "$TEST_DIR/body4" > "$TEST_DIR/out4"
if cmp -s "$TEST_DIR/body4" "$TEST_DIR/out4"; then
  pass "TC-004: body unchanged when 進捗 section absent"
else
  fail "TC-004: body changed despite absent section"
fi
echo ""

# ─── TC-005: section at EOF → items appended, trailing newline preserved ─
echo "TC-005: section at EOF → items appended, trailing newline preserved"
body5=$'## 📜 rite 作業メモリ\n\n### 進捗\n- [x] 実装完了\n'
printf '%s' "$body5" | python3 "$PY" merge-checklist --section 進捗 --content-file "$items_file" > "$TEST_DIR/out5"
if grep -qxF -- "- [x] クリーンアップ完了" "$TEST_DIR/out5"; then
  pass "TC-005a: items appended to EOF section"
else
  fail "TC-005a: items not appended at EOF"
fi
if [ -z "$(tail -c1 "$TEST_DIR/out5")" ]; then
  pass "TC-005b: trailing newline preserved"
else
  fail "TC-005b: trailing newline lost"
fi
echo ""

# ─── TC-006: empty content-file → body unchanged (no-op) ─────────────────
echo "TC-006: empty content-file → no-op"
: > "$TEST_DIR/empty.txt"
body6=$'## 📜 rite 作業メモリ\n\n### 進捗\n- [x] 実装完了\n'
printf '%s' "$body6" > "$TEST_DIR/body6"
python3 "$PY" merge-checklist --section 進捗 --content-file "$TEST_DIR/empty.txt" < "$TEST_DIR/body6" > "$TEST_DIR/out6"
if cmp -s "$TEST_DIR/body6" "$TEST_DIR/out6"; then
  pass "TC-006: body unchanged when content-file is empty"
else
  fail "TC-006: body changed despite empty content-file"
fi
echo ""

# ─── TC-007: input without trailing newline → output also lacks it ───────
echo "TC-007: no trailing newline preserved (negative branch of the newline guard)"
body7=$'## 📜 rite 作業メモリ\n\n### 進捗\n- [x] 実装完了'
printf '%s' "$body7" | python3 "$PY" merge-checklist --section 進捗 --content-file "$items_file" > "$TEST_DIR/out7"
if grep -qxF -- "- [x] クリーンアップ完了" "$TEST_DIR/out7"; then
  pass "TC-007a: items appended (EOF section, no trailing newline input)"
else
  fail "TC-007a: items not appended"
fi
if [ -n "$(tail -c1 "$TEST_DIR/out7")" ]; then
  pass "TC-007b: no trailing newline added when input had none"
else
  fail "TC-007b: a trailing newline was incorrectly added"
fi
echo ""

# ─── TC-008: multiple ### 進捗 sections → items go to the LAST block ──────
echo "TC-008: multiple 進捗 sections → insert at last block (verbatim with original)"
body8=$'## 📜 rite 作業メモリ\n\n### 進捗\n- [x] 古い進捗\n\n### 進捗\n- [x] 新しい進捗\n\n### 完了情報\n- x\n'
printf '%s' "$body8" | python3 "$PY" merge-checklist --section 進捗 --content-file "$items_file" > "$TEST_DIR/out8"
old_ln=$(grep -nF -- "- [x] 古い進捗" "$TEST_DIR/out8" | head -1 | cut -d: -f1 || true)
new_ln=$(grep -nF -- "- [x] 新しい進捗" "$TEST_DIR/out8" | head -1 | cut -d: -f1 || true)
item_ln8=$(grep -nF -- "- [x] レビュー完了" "$TEST_DIR/out8" | head -1 | cut -d: -f1 || true)
done_ln8=$(grep -nF -- "### 完了情報" "$TEST_DIR/out8" | head -1 | cut -d: -f1 || true)
# items must land after the SECOND (last) 進捗 block's content (after 新しい進捗) and before 完了情報,
# NOT immediately after the first block (古い進捗)
if [ -n "$item_ln8" ] && [ -n "$new_ln" ] && [ -n "$done_ln8" ] \
   && [ "$item_ln8" -gt "$new_ln" ] && [ "$item_ln8" -lt "$done_ln8" ]; then
  pass "TC-008: items inserted at last 進捗 block (after 新しい進捗, before 完了情報)"
else
  fail "TC-008: insertion at wrong 進捗 block (古い=$old_ln, 新しい=$new_ln, item=$item_ln8, 完了情報=$done_ln8)"
fi
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
