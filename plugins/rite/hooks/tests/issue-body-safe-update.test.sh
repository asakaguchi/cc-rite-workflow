#!/bin/bash
# issue-body-safe-update.test.sh — CG-3 (PR #1079 verified-review)
#
# Purpose:
#   `issue-body-safe-update.sh` の apply mode の安全装置 (50% shrinkage guard、
#   empty-write rejection、missing-args 検出、diff-check 短絡) を unit test で pin する。
#   apply mode は start.md ステップ 3.5 と create.md ステップ 5.5 の核となる安全装置で、
#   従来 0 test だった (PR #1079 review CG-3)。
#
# Coverage:
#   - apply with missing args → exit 1 (argument error)
#   - apply with empty write file → exit 0 + WARNING + cleanup
#   - apply with < 50% shrinkage → exit 0 + WARNING + cleanup (body 消失防止)
#   - apply --diff-check with identical files → exit 0 + INFO + cleanup
#   - fetch with missing --issue → exit 1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
TARGET="$PLUGIN_ROOT/hooks/issue-body-safe-update.sh"

[ -f "$TARGET" ] || { echo "ERROR: $TARGET not found" >&2; exit 1; }

# Helper: assert exit code matches expectation
assert_exit() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" -eq "$expected" ]; then
    pass "$label (exit $actual)"
  else
    fail "$label (expected exit $expected, got $actual)"
  fi
}

echo "=== Phase 1: apply mode argument errors ==="
rc=0
bash "$TARGET" apply --issue 999 >/dev/null 2>&1 || rc=$?
assert_exit "TC-01 apply without tmpfile-* + original-length → exit 1" 1 "$rc"

rc=0
bash "$TARGET" apply --issue 999 --tmpfile-read /tmp/foo >/dev/null 2>&1 || rc=$?
assert_exit "TC-02 apply with partial args → exit 1" 1 "$rc"

echo "=== Phase 2: apply mode empty write rejection ==="
tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'original body content here\n' > "$tmp_read"
: > "$tmp_write"  # empty write file
rc=0
out=$(bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 30 2>&1) || rc=$?
assert_exit "TC-03 empty tmpfile-write → exit 0 (non-blocking skip)" 0 "$rc"
if printf '%s' "$out" | grep -q '更新内容が空\|empty'; then
  pass "TC-04 empty write emits WARNING with 空 / empty message"
else
  fail "TC-04 empty write WARNING missing in output: $out"
fi
[ ! -f "$tmp_read" ] && pass "TC-05 empty write cleaned tmpfile-read" || fail "TC-05 tmpfile-read leak"
[ ! -f "$tmp_write" ] && pass "TC-06 empty write cleaned tmpfile-write" || fail "TC-06 tmpfile-write leak"

echo "=== Phase 3: apply mode 50% shrinkage guard ==="
tmp_read=$(mktemp)
tmp_write=$(mktemp)
# original=100 bytes
printf '%s' "$(head -c 100 /dev/urandom | tr -dc 'a-z' | head -c 100)" > "$tmp_read"
# write=10 bytes (10% — well under 50%)
printf 'short' > "$tmp_write"
rc=0
out=$(bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 100 2>&1) || rc=$?
assert_exit "TC-07 < 50% shrinkage → exit 0 (non-blocking skip)" 0 "$rc"
if printf '%s' "$out" | grep -q 'body 消失\|50%未満\|shrinkage'; then
  pass "TC-08 shrinkage guard emits WARNING with 消失 / 50% message"
else
  fail "TC-08 shrinkage WARNING missing in output: $out"
fi
[ ! -f "$tmp_read" ] && pass "TC-09 shrinkage skip cleaned tmpfile-read" || fail "TC-09 tmpfile-read leak"

echo "=== Phase 4: apply mode diff-check short-circuit ==="
tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'identical content\n' > "$tmp_read"
printf 'identical content\n' > "$tmp_write"
rc=0
out=$(bash "$TARGET" apply --issue 999 --diff-check --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 18 2>&1) || rc=$?
assert_exit "TC-10 diff-check identical → exit 0 (skip)" 0 "$rc"
if printf '%s' "$out" | grep -q 'INFO\|変更なし\|already'; then
  pass "TC-11 diff-check emits INFO on identical files"
else
  fail "TC-11 diff-check INFO missing: $out"
fi

echo "=== Phase 5: fetch mode argument errors ==="
rc=0
bash "$TARGET" fetch >/dev/null 2>&1 || rc=$?
assert_exit "TC-12 fetch without --issue → exit 1" 1 "$rc"

echo "=== Phase 6: unknown mode ==="
rc=0
bash "$TARGET" unknown_mode --issue 999 >/dev/null 2>&1 || rc=$?
assert_exit "TC-13 unknown mode → exit 1" 1 "$rc"

print_summary "$(basename "$0")" "If you weaken or remove the 50% shrinkage guard / empty-write rejection / missing-args check in issue-body-safe-update.sh, body truncation regressions become silent. Keep the guards intact and update the test if the guards intentionally change."
