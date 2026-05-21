#!/bin/bash
# issue-body-safe-update.test.sh
#
# Pin the apply-mode safety net (50% shrinkage guard, empty-write rejection,
# missing-args detection, diff-check short-circuit) plus the incident emit
# invariants. Without these guards, a body update with a truncated payload
# could silently destroy the Issue body, and a transient gh failure could
# vanish without an incident record.

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

echo "=== Phase 7: apply mode happy-path with mock gh ==="
# Negative-path TCs above don't exercise the happy path through gh. Mock gh
# pins three invariants: --body-file argument shape, exit-0 + cleanup on
# success, and exit-0 + cleanup + WARNING on gh failure (non-blocking contract).
mock_bin=$(mktemp -d)
trap_orig=""
cat > "$mock_bin/gh" <<'MOCK_OK'
#!/bin/bash
# Inline mock: log invocation to MOCK_LOG, succeed exit 0.
echo "gh $*" >> "${MOCK_LOG:-/dev/null}"
exit 0
MOCK_OK
chmod +x "$mock_bin/gh"

tmp_read=$(mktemp)
tmp_write=$(mktemp)
mock_log=$(mktemp)
# 200/250 byte 確定で書き込む (urandom + tr -dc 'a-z' は output が短くなる risk があるので避ける)
printf 'a%.0s' $(seq 1 200) > "$tmp_read"
printf 'b%.0s' $(seq 1 250) > "$tmp_write"
rc=0
out=$(PATH="$mock_bin:$PATH" MOCK_LOG="$mock_log" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 200 2>&1) || rc=$?
assert_exit "TC-14 apply happy-path → exit 0" 0 "$rc"
if grep -q 'issue edit 999 --body-file' "$mock_log"; then
  pass "TC-15 apply called gh issue edit with --body-file"
else
  fail "TC-15 mock gh log missing 'issue edit ... --body-file': $(cat "$mock_log")"
fi
[ ! -f "$tmp_read" ] && pass "TC-16 apply happy-path cleaned tmpfile-read" || fail "TC-16 tmpfile-read leak"
[ ! -f "$tmp_write" ] && pass "TC-17 apply happy-path cleaned tmpfile-write" || fail "TC-17 tmpfile-write leak"
rm -f "$mock_log"

# TC-18-20: gh issue edit failure path (exit !=0 + stderr captured)
cat > "$mock_bin/gh" <<'MOCK_FAIL'
#!/bin/bash
# Inline mock: fail with stderr message ("rate limit" 等を模擬)
echo "HTTP 403: API rate limit exceeded for user" >&2
exit 1
MOCK_FAIL
chmod +x "$mock_bin/gh"

tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'a%.0s' $(seq 1 200) > "$tmp_read"
printf 'b%.0s' $(seq 1 250) > "$tmp_write"
rc=0
out=$(PATH="$mock_bin:$PATH" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 200 2>&1) || rc=$?
assert_exit "TC-18 apply gh failure → exit 0 (non-blocking)" 0 "$rc"
if printf '%s' "$out" | grep -q 'gh issue edit 失敗.*rate limit\|apply_failure_reason=gh_edit_failed'; then
  pass "TC-19 apply gh failure emits WARNING with root cause + failure reason"
else
  fail "TC-19 apply gh failure WARNING missing in output: $out"
fi
[ ! -f "$tmp_read" ] && pass "TC-20 apply gh failure cleaned tmpfile-read" || fail "TC-20 tmpfile-read leak after gh failure"
[ ! -f "$tmp_write" ] && pass "TC-21 apply gh failure cleaned tmpfile-write" || fail "TC-21 tmpfile-write leak after gh failure"

rm -rf "$mock_bin"

# ==========================================================================
# Incident emit invocation guarantees: without these assertions a refactor
# can drop the fetch_failure_reason / root-cause-hint signal silently, and
# operators lose visibility into auth/network/permission failures.
# ==========================================================================

echo "=== Phase 8: _emit_body_update_incident runtime invocation ==="
# Mock _EMIT_SH (or production _EMIT_SH if the override path doesn't apply) must
# see the type when gh issue view fails.
mock_bin2=$(mktemp -d)
emit_log=$(mktemp)
cat > "$mock_bin2/gh" <<'MOCK_FETCH_FAIL'
#!/bin/bash
echo "HTTP 404: Issue not found" >&2
exit 1
MOCK_FETCH_FAIL
chmod +x "$mock_bin2/gh"

mock_emit=$(mktemp /tmp/rite-mock-emit-XXXXXX.sh)
cat > "$mock_emit" <<MOCK_EMIT
#!/bin/bash
echo "EMIT: \$*" >> "$emit_log"
exit 0
MOCK_EMIT
chmod +x "$mock_emit"

rc=0
out=$(PATH="$mock_bin2:$PATH" _EMIT_SH_OVERRIDE="$mock_emit" bash -c '
  # _EMIT_SH is resolved at top of script via PLUGIN_ROOT detection. Override by
  # exporting _EMIT_SH explicitly — the script sees it before its own resolution
  # because we re-source the script body with the override path injected.
  export _EMIT_SH="$_EMIT_SH_OVERRIDE"
  bash "$1" fetch --issue 999
' _ "$TARGET" 2>&1) || rc=$?
# 注: 上のラップが _EMIT_SH を override しないケース (script が自前で再解決する場合)
# は emit_log が空になる。その場合は production _EMIT_SH が呼ばれた可能性を grep で確認する。
assert_exit "TC-22 fetch failure → exit 0 (non-blocking)" 0 "$rc"
if grep -q 'issue_body_fetch_failed\|fetch_failure_reason=gh_view_failed' "$emit_log" 2>/dev/null; then
  pass "TC-22 fetch failure invoked _emit_body_update_incident (or emitted fetch_failure_reason)"
elif printf '%s' "$out" | grep -q 'fetch_failure_reason=gh_view_failed\|issue_body_fetch_failed'; then
  pass "TC-22 fetch failure stdout contains fetch_failure_reason or incident type"
else
  fail "TC-22 fetch failure did not invoke emit nor produce fetch_failure_reason. emit_log=$(cat "$emit_log" 2>/dev/null); out=$out"
fi
rm -f "$emit_log" "$mock_emit"
rm -rf "$mock_bin2"

echo "=== Phase 9: _EMIT_SH absent → fallback sentinel ==="
mock_bin3=$(mktemp -d)
cat > "$mock_bin3/gh" <<'MOCK_FAIL2'
#!/bin/bash
echo "HTTP 500 mock failure" >&2
exit 1
MOCK_FAIL2
chmod +x "$mock_bin3/gh"

# Point _EMIT_SH to a non-existent path. We do this by running the script in an
# environment where the plugin root resolution would land on a tempdir without
# workflow-incident-emit.sh.
fake_plugin_root=$(mktemp -d)
mkdir -p "$fake_plugin_root/hooks"
# Copy script under fake root and run from there. The script computes _EMIT_SH
# via SCRIPT_DIR (relative to itself), so placing it in a hook-less dir makes
# _EMIT_SH resolve to a non-executable path.
cp "$TARGET" "$fake_plugin_root/hooks/issue-body-safe-update.sh"
# Note: we do NOT copy workflow-incident-emit.sh, so [ -x "$_EMIT_SH" ] is false.

rc=0
out=$(PATH="$mock_bin3:$PATH" bash "$fake_plugin_root/hooks/issue-body-safe-update.sh" fetch --issue 999 2>&1) || rc=$?
assert_exit "TC-23 fetch failure with absent _EMIT_SH → exit 0" 0 "$rc"
if printf '%s' "$out" | grep -qE '\[rite\]\[incident\] type=issue_body_fetch_failed|fallback sentinel'; then
  pass "TC-23 fallback sentinel emitted when _EMIT_SH absent (observability preserved)"
else
  # Permissible fallback: at minimum fetch_failure_reason= line must still appear.
  if printf '%s' "$out" | grep -q 'fetch_failure_reason='; then
    pass "TC-23 _EMIT_SH absent: fetch_failure_reason= stdout still emitted (caller can detect)"
  else
    fail "TC-23 _EMIT_SH absent + no fallback sentinel + no fetch_failure_reason. out=$out"
  fi
fi
rm -rf "$mock_bin3" "$fake_plugin_root"

echo "=== Phase 10: apply mode failure emits gh_edit_failed root cause ==="
mock_bin4=$(mktemp -d)
cat > "$mock_bin4/gh" <<'MOCK_EDIT_FAIL'
#!/bin/bash
echo "API error during edit" >&2
exit 1
MOCK_EDIT_FAIL
chmod +x "$mock_bin4/gh"

tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'a%.0s' $(seq 1 200) > "$tmp_read"
printf 'b%.0s' $(seq 1 250) > "$tmp_write"
rc=0
out=$(PATH="$mock_bin4:$PATH" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 200 2>&1) || rc=$?
assert_exit "TC-24 apply gh failure → exit 0" 0 "$rc"
if printf '%s' "$out" | grep -qE 'apply_failure_reason=gh_edit_failed|root_cause_hint=gh_edit_failed|gh_edit_failed'; then
  pass "TC-24 apply failure produces gh_edit_failed root cause hint"
else
  fail "TC-24 apply failure missing gh_edit_failed in output: $out"
fi
rm -rf "$mock_bin4"

print_summary "$(basename "$0")" "If you weaken or remove the 50% shrinkage guard / empty-write rejection / missing-args check / gh-edit error capture / _emit_body_update_incident fallback in issue-body-safe-update.sh, body truncation or silent auth-failure regressions become invisible. Keep the guards intact and update the test if the guards intentionally change."
