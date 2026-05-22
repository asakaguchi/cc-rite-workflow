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
# `if ! cmd; then rc=$?` forces rc=0 inside the then-branch — regression guard
# for the canonical `if cmd; then :; else rc=$?` form. The mock gh exits 1, so
# the incident details must report rc=1, not rc=0.
if printf '%s' "$out" | grep -qE 'rc=1\b'; then
  pass "TC-19b apply gh failure reports actual gh rc (rc=1, not rc=0)"
else
  fail "TC-19b apply gh failure reported wrong rc (likely rc=0 from if-! antipattern): $out"
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
# The script honors a pre-exported `_EMIT_SH` via `: "${_EMIT_SH:=...}"`, so
# injecting a mock emit and asserting it received the type + rc + reason is
# the only way to catch regressions in `_emit_body_update_incident` itself.
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
out=$(PATH="$mock_bin2:$PATH" _EMIT_SH="$mock_emit" bash "$TARGET" fetch --issue 999 2>&1) || rc=$?
assert_exit "TC-22 fetch failure → exit 0 (non-blocking)" 0 "$rc"
if grep -q -- '--type issue_body_fetch_failed' "$emit_log"; then
  pass "TC-22 fetch failure invoked mock _emit_body_update_incident with type=issue_body_fetch_failed"
else
  fail "TC-22 mock emit log missing --type issue_body_fetch_failed: $(cat "$emit_log" 2>/dev/null); out=$out"
fi
if grep -qE 'rc=1\b' "$emit_log"; then
  pass "TC-22b emit details report actual gh rc=1 (regression guard for if-! antipattern)"
else
  fail "TC-22b emit details missing rc=1 (likely rc=0 from if-! pattern): $(cat "$emit_log" 2>/dev/null)"
fi
if grep -q -- '--root-cause-hint gh_view_failed' "$emit_log"; then
  pass "TC-22c emit invoked with root-cause-hint=gh_view_failed"
else
  fail "TC-22c emit missing --root-cause-hint gh_view_failed: $(cat "$emit_log" 2>/dev/null)"
fi
rm -f "$emit_log" "$mock_emit"
rm -rf "$mock_bin2"

echo "=== Phase 9: _EMIT_SH absent → canonical fallback sentinel ==="
mock_bin3=$(mktemp -d)
cat > "$mock_bin3/gh" <<'MOCK_FAIL2'
#!/bin/bash
echo "HTTP 500 mock failure" >&2
exit 1
MOCK_FAIL2
chmod +x "$mock_bin3/gh"

# Point `_EMIT_SH` at a non-executable path so the fallback branch runs. The
# fallback must echo the canonical `[CONTEXT] WORKFLOW_INCIDENT=1; ...` sentinel
# that workflow-incident-detection.md greps — any other format (e.g. the legacy
# `[rite][incident]`) is invisible to the orchestrator.
absent_emit="/nonexistent/path/workflow-incident-emit.sh"

rc=0
out=$(PATH="$mock_bin3:$PATH" _EMIT_SH="$absent_emit" bash "$TARGET" fetch --issue 999 2>&1) || rc=$?
assert_exit "TC-23 fetch failure with absent _EMIT_SH → exit 0" 0 "$rc"
if printf '%s' "$out" | grep -qE '\[CONTEXT\] WORKFLOW_INCIDENT=1; type=issue_body_fetch_failed'; then
  pass "TC-23 fallback emits canonical [CONTEXT] WORKFLOW_INCIDENT=1 sentinel"
else
  fail "TC-23 fallback did not emit canonical sentinel format. out=$out"
fi
if printf '%s' "$out" | grep -qE 'root_cause_hint=gh_view_failed'; then
  pass "TC-23b canonical fallback includes root_cause_hint=gh_view_failed"
else
  fail "TC-23b canonical fallback missing root_cause_hint=gh_view_failed: $out"
fi
if printf '%s' "$out" | grep -qE 'iteration_id=0-[0-9]+'; then
  pass "TC-23c canonical fallback includes iteration_id=0-<epoch>"
else
  fail "TC-23c canonical fallback missing iteration_id=0-<epoch>: $out"
fi
rm -rf "$mock_bin3"

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
# AND-style assertion: collapsing apply_failure_reason / root_cause_hint into a
# single OR would let regressions delete either signal silently.
if printf '%s' "$out" | grep -qE 'apply_failure_reason=gh_edit_failed'; then
  pass "TC-24 apply failure emits apply_failure_reason=gh_edit_failed"
else
  fail "TC-24 apply failure missing apply_failure_reason=gh_edit_failed: $out"
fi
if printf '%s' "$out" | grep -qE 'rc=1\b'; then
  pass "TC-24b apply failure reports actual gh rc=1 (if-! antipattern regression guard)"
else
  fail "TC-24b apply failure reported wrong rc (likely rc=0): $out"
fi
rm -rf "$mock_bin4"

echo ""
echo "=== Phase 10: apply mode + _EMIT_SH absent → canonical fallback sentinel ==="
# Fetch mode at TC-23 verifies the _EMIT_SH fallback emits the canonical
# `[CONTEXT] WORKFLOW_INCIDENT=1; type=issue_body_fetch_failed; ...
# iteration_id=0-<epoch>` line when the emit helper is missing. The same
# fallback path on apply mode (helper line 64 inline sentinel) was previously
# unverified, leaving deployment-degraded scenarios silently broken on apply.
mock_bin5=$(mktemp -d)
cat > "$mock_bin5/gh" <<'MOCK_EDIT_FAIL'
#!/bin/bash
case "$1 $2" in
  "issue edit") echo "HTTP 401: bad credentials" >&2; exit 1 ;;
esac
exit 0
MOCK_EDIT_FAIL
chmod +x "$mock_bin5/gh"
absent_emit_apply="$mock_bin5/nonexistent_emit_sh"
tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'a%.0s' $(seq 1 200) > "$tmp_read"
printf 'b%.0s' $(seq 1 250) > "$tmp_write"
rc=0
out=$(PATH="$mock_bin5:$PATH" _EMIT_SH="$absent_emit_apply" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 200 2>&1) || rc=$?
assert_exit "TC-25 apply failure with absent _EMIT_SH → exit 0" 0 "$rc"
if printf '%s' "$out" | grep -qE '\[CONTEXT\] WORKFLOW_INCIDENT=1; type=issue_body_fetch_failed'; then
  pass "TC-25 apply fallback emits canonical sentinel even when _EMIT_SH is absent"
else
  fail "TC-25 apply fallback sentinel missing — degraded deployment silently loses observability: $out"
fi
if printf '%s' "$out" | grep -qE 'root_cause_hint=gh_edit_failed'; then
  pass "TC-25b apply fallback preserves root_cause_hint=gh_edit_failed"
else
  fail "TC-25b apply fallback root_cause_hint missing: $out"
fi
if printf '%s' "$out" | grep -qE 'iteration_id=0-[0-9]+'; then
  pass "TC-25c apply fallback uses canonical iteration_id=<pr>-<epoch> format"
else
  fail "TC-25c apply fallback iteration_id format drift: $out"
fi
rm -rf "$mock_bin5"

echo ""
echo "=== Phase 11: apply mktemp_failed surfaces incident ==="
# A regression that drops the emit on apply mktemp failure would lose the
# observability that the safety net exists at all. Shadow mktemp to fail only
# on the rite-issue-body-apply-err-* pattern so the rest of the script runs.
mock_bin6=$(mktemp -d)
cat > "$mock_bin6/mktemp" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    /tmp/rite-issue-body-apply-err-*) exit 1 ;;
  esac
done
exec /usr/bin/mktemp "$@"
EOF
chmod +x "$mock_bin6/mktemp"
cat > "$mock_bin6/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$mock_bin6/gh"
tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'a%.0s' $(seq 1 200) > "$tmp_read"
printf 'b%.0s' $(seq 1 250) > "$tmp_write"
rc=0
out=$(PATH="$mock_bin6:$PATH" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 200 2>&1) || rc=$?
if printf '%s' "$out" | grep -qE 'mktemp apply_err failed'; then
  pass "TC-26 apply mktemp failure emits WARNING (regression guard for stderr capture disabled path)"
else
  fail "TC-26 apply mktemp WARNING missing: $out"
fi
if printf '%s' "$out" | grep -qE 'root_cause_hint=mktemp_failed'; then
  pass "TC-26b apply mktemp failure carries root_cause_hint=mktemp_failed"
else
  fail "TC-26b apply mktemp incident root_cause_hint missing: $out"
fi
rm -rf "$mock_bin6"

echo ""
echo "=== Phase 12: diff IO error rc>=2 → skip apply with WARNING (not gh edit) ==="
# A refactor to `if ! diff ...; then` would treat rc=2 (file unreadable / IO
# error) identically to rc=1 (files differ) and proceed to gh edit, risking
# data loss. The case branch on _diff_rc must distinguish IO failure.
mock_bin7=$(mktemp -d)
# Shadow diff to always return rc=2 (IO error)
cat > "$mock_bin7/diff" <<'EOF'
#!/bin/bash
echo "diff: cannot read file" >&2
exit 2
EOF
chmod +x "$mock_bin7/diff"
# gh mock counts invocations so a regression that calls gh after IO error fails the assert
cat > "$mock_bin7/gh" <<'EOF'
#!/bin/bash
echo "GH_INVOKED" >&2
exit 0
EOF
chmod +x "$mock_bin7/gh"
tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'a%.0s' $(seq 1 200) > "$tmp_read"
printf 'b%.0s' $(seq 1 250) > "$tmp_write"
rc=0
out=$(PATH="$mock_bin7:$PATH" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 200 --diff-check 2>&1) || rc=$?
assert_exit "TC-27 diff IO error → exit 0 (skip apply)" 0 "$rc"
if printf '%s' "$out" | grep -qE 'diff コマンドが IO エラー.*rc=2'; then
  pass "TC-27 diff IO error WARNING reports rc=2 explicitly"
else
  fail "TC-27 diff IO error WARNING missing or rc not reported: $out"
fi
if printf '%s' "$out" | grep -qE 'GH_INVOKED'; then
  fail "TC-27 critical: gh issue edit was invoked despite diff IO error (data loss risk)"
else
  pass "TC-27 gh issue edit NOT invoked after diff IO error (data loss prevented)"
fi
rm -rf "$mock_bin7"

echo ""
echo "=== Phase 13: shrinkage trip × _EMIT_SH absent → body_shrinkage_guard_tripped sentinel ==="
# `_emit_body_update_incident` now accepts the incident type as its 1st arg.
# TC-25/25b/25c pinned the `issue_body_fetch_failed` fallback only. Shrinkage
# trip + missing emit helper must surface as `body_shrinkage_guard_tripped` in
# the canonical sentinel — without this TC, a refactor that hardcodes the type
# literal in the fallback printf would pass all existing TCs.
mock_bin8=$(mktemp -d)
cat > "$mock_bin8/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$mock_bin8/gh"
absent_emit_shrink="$mock_bin8/nonexistent_emit"
tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'a%.0s' $(seq 1 200) > "$tmp_read"
# 5 bytes ≪ 200/2 — triggers shrinkage guard
printf 'aaaaa' > "$tmp_write"
rc=0
out=$(PATH="$mock_bin8:$PATH" _EMIT_SH="$absent_emit_shrink" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 200 2>&1) || rc=$?
assert_exit "TC-25d shrinkage trip with absent _EMIT_SH → exit 0" 0 "$rc"
if printf '%s' "$out" | grep -qE '\[CONTEXT\] WORKFLOW_INCIDENT=1; type=body_shrinkage_guard_tripped'; then
  pass "TC-25d shrinkage trip emits canonical sentinel with type=body_shrinkage_guard_tripped"
else
  fail "TC-25d shrinkage sentinel missing or wrong type: $out"
fi
if printf '%s' "$out" | grep -qE 'root_cause_hint=shrinkage_below_50pct'; then
  pass "TC-25d sentinel carries root_cause_hint=shrinkage_below_50pct"
else
  fail "TC-25d root_cause_hint missing: $out"
fi
rm -rf "$mock_bin8"

echo ""
echo "=== Phase 14: empty write × _EMIT_SH absent → body_shrinkage_guard_tripped (empty_write) ==="
mock_bin9=$(mktemp -d)
cat > "$mock_bin9/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$mock_bin9/gh"
absent_emit_empty="$mock_bin9/nonexistent_emit"
tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'a%.0s' $(seq 1 200) > "$tmp_read"
# zero bytes — triggers empty-write guard
: > "$tmp_write"
rc=0
out=$(PATH="$mock_bin9:$PATH" _EMIT_SH="$absent_emit_empty" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 200 2>&1) || rc=$?
assert_exit "TC-25e empty write with absent _EMIT_SH → exit 0" 0 "$rc"
if printf '%s' "$out" | grep -qE '\[CONTEXT\] WORKFLOW_INCIDENT=1; type=body_shrinkage_guard_tripped'; then
  pass "TC-25e empty write emits canonical sentinel with type=body_shrinkage_guard_tripped"
else
  fail "TC-25e empty-write sentinel missing or wrong type: $out"
fi
if printf '%s' "$out" | grep -qE 'root_cause_hint=empty_write'; then
  pass "TC-25e sentinel carries root_cause_hint=empty_write"
else
  fail "TC-25e empty-write root_cause_hint missing: $out"
fi
rm -rf "$mock_bin9"

echo ""
echo "=== Phase 15: --original-length non-numeric → body_shrinkage_guard_tripped with original_length_invalid hint ==="
# The defensive validation against non-numeric --original-length was added
# specifically so that an upstream `wc` failure (which can return whitespace
# or empty under `set -euo pipefail`) doesn't abort apply-mode via arithmetic
# evaluation. Without this TC, dropping the regex check or mis-typing the
# hint would silently revert to the original `arithmetic syntax error` abort
# path that leaks tmpfiles and breaks the non-blocking contract.
mock_bin10=$(mktemp -d)
cat > "$mock_bin10/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$mock_bin10/gh"
tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'sample body' > "$tmp_read"
printf 'updated body' > "$tmp_write"
rc=0
out=$(PATH="$mock_bin10:$PATH" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length "abc" 2>&1) || rc=$?
assert_exit "TC-25f apply with non-numeric --original-length → exit 0 (non-blocking)" 0 "$rc"
if printf '%s' "$out" | grep -qE '\[CONTEXT\] WORKFLOW_INCIDENT=1; type=body_shrinkage_guard_tripped'; then
  pass "TC-25f non-numeric --original-length emits body_shrinkage_guard_tripped sentinel"
else
  fail "TC-25f sentinel missing: $out"
fi
if printf '%s' "$out" | grep -qE 'root_cause_hint=original_length_invalid'; then
  pass "TC-25f sentinel carries root_cause_hint=original_length_invalid (distinct from shrinkage_below_50pct / empty_write)"
else
  fail "TC-25f original_length_invalid hint missing — caller cannot distinguish from a real shrinkage trip: $out"
fi
# Confirm tmpfiles were cleaned up (the original arithmetic abort path would leak them).
if [ ! -f "$tmp_read" ] && [ ! -f "$tmp_write" ]; then
  pass "TC-25f tmpfiles cleaned up under defensive abort"
else
  fail "TC-25f tmpfiles leaked under defensive abort (read present=$([ -f "$tmp_read" ] && echo y || echo n), write present=$([ -f "$tmp_write" ] && echo y || echo n))"
fi
rm -rf "$mock_bin10"

print_summary "$(basename "$0")" "If you weaken or remove the 50% shrinkage guard / empty-write rejection / missing-args check / gh-edit error capture / _emit_body_update_incident fallback in issue-body-safe-update.sh, body truncation or silent auth-failure regressions become invisible. Keep the guards intact and update the test if the guards intentionally change."
