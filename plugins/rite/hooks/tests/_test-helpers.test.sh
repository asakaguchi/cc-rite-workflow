#!/bin/bash
# Self-test for _test-helpers.sh (Issue #852)
#
# Each test case runs in a subshell that re-sources _test-helpers.sh,
# so we can observe how the helpers mutate the PASS / FAIL / FAILED_NAMES
# counters in isolation without polluting our own outer counters.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS="$SCRIPT_DIR/_test-helpers.sh"

# Outer-test counters (use plain integers to avoid colliding with helper counters
# loaded inside subshells under test).
OUTER_PASS=0
OUTER_FAIL=0
OUTER_FAILED=()

outer_pass() { OUTER_PASS=$((OUTER_PASS + 1)); echo "  ✅ $1"; }
outer_fail() { OUTER_FAIL=$((OUTER_FAIL + 1)); OUTER_FAILED+=("$1"); echo "  ❌ $1"; }

if [ ! -f "$HELPERS" ]; then
  echo "FATAL: $HELPERS not found"
  exit 1
fi

# === TC-1: path resolvers ===
echo "TC-1: _helpers_resolve_plugin_root / _helpers_resolve_repo_root"

expected_plugin_root=$(cd "$SCRIPT_DIR/../.." && pwd)
expected_repo_root=$(cd "$SCRIPT_DIR/../../../.." && pwd)

actual_plugin_root=$(bash -c "source '$HELPERS' && _helpers_resolve_plugin_root '$SCRIPT_DIR'")
if [ "$actual_plugin_root" = "$expected_plugin_root" ]; then
  outer_pass "TC-1.1: _helpers_resolve_plugin_root returns plugins/rite"
else
  outer_fail "TC-1.1: expected='$expected_plugin_root' actual='$actual_plugin_root'"
fi

actual_repo_root=$(bash -c "source '$HELPERS' && _helpers_resolve_repo_root '$SCRIPT_DIR'")
if [ "$actual_repo_root" = "$expected_repo_root" ]; then
  outer_pass "TC-1.2: _helpers_resolve_repo_root returns repo root"
else
  outer_fail "TC-1.2: expected='$expected_repo_root' actual='$actual_repo_root'"
fi

# === TC-2: pass / fail mutate counters ===
echo
echo "TC-2: pass / fail counter mutation"

# capture inner PASS / FAIL / FAILED_NAMES state in subshell
inner_state=$(bash -c "
  source '$HELPERS'
  pass 'sample-pass'   >/dev/null
  pass 'sample-pass-2' >/dev/null
  fail 'sample-fail'   >/dev/null
  echo \"PASS=\$PASS\"
  echo \"FAIL=\$FAIL\"
  echo \"FAILED_COUNT=\${#FAILED_NAMES[@]}\"
  echo \"FAILED_HEAD=\${FAILED_NAMES[0]:-}\"
")

inner_pass=$(echo "$inner_state" | grep '^PASS=' | cut -d= -f2)
inner_fail=$(echo "$inner_state" | grep '^FAIL=' | cut -d= -f2)
inner_failed_count=$(echo "$inner_state" | grep '^FAILED_COUNT=' | cut -d= -f2)
inner_failed_head=$(echo "$inner_state" | grep '^FAILED_HEAD=' | cut -d= -f2)

if [ "$inner_pass" = "2" ]; then
  outer_pass "TC-2.1: pass() increments PASS to 2"
else
  outer_fail "TC-2.1: expected PASS=2 got PASS=$inner_pass"
fi

if [ "$inner_fail" = "1" ]; then
  outer_pass "TC-2.2: fail() increments FAIL to 1"
else
  outer_fail "TC-2.2: expected FAIL=1 got FAIL=$inner_fail"
fi

if [ "$inner_failed_count" = "1" ] && [ "$inner_failed_head" = "sample-fail" ]; then
  outer_pass "TC-2.3: fail() appends label to FAILED_NAMES"
else
  outer_fail "TC-2.3: expected count=1 head='sample-fail' got count=$inner_failed_count head='$inner_failed_head'"
fi

# === TC-3: assert ===
echo
echo "TC-3: assert (equality)"

assert_state=$(bash -c "
  source '$HELPERS'
  assert 'eq-match'  'foo' 'foo' >/dev/null
  assert 'eq-mismatch' 'foo' 'bar' >/dev/null
  echo \"PASS=\$PASS\"
  echo \"FAIL=\$FAIL\"
")
ap=$(echo "$assert_state" | grep '^PASS=' | cut -d= -f2)
af=$(echo "$assert_state" | grep '^FAIL=' | cut -d= -f2)
if [ "$ap" = "1" ] && [ "$af" = "1" ]; then
  outer_pass "TC-3.1: assert passes on equal, fails on unequal"
else
  outer_fail "TC-3.1: expected PASS=1 FAIL=1 got PASS=$ap FAIL=$af"
fi

# === TC-4: assert_grep / assert_not_grep ===
echo
echo "TC-4: assert_grep / assert_not_grep"

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
printf 'hello world\nfoo bar\n' > "$tmpfile"

grep_state=$(bash -c "
  source '$HELPERS'
  assert_grep     'present'   '$tmpfile' 'hello'   >/dev/null
  assert_grep     'absent'    '$tmpfile' 'missing' >/dev/null
  assert_not_grep 'absent-ok' '$tmpfile' 'missing' >/dev/null
  assert_not_grep 'present-bad' '$tmpfile' 'hello' >/dev/null
  echo \"PASS=\$PASS\"
  echo \"FAIL=\$FAIL\"
")
gp=$(echo "$grep_state" | grep '^PASS=' | cut -d= -f2)
gf=$(echo "$grep_state" | grep '^FAIL=' | cut -d= -f2)
if [ "$gp" = "2" ] && [ "$gf" = "2" ]; then
  outer_pass "TC-4.1: assert_grep / assert_not_grep route correctly"
else
  outer_fail "TC-4.1: expected PASS=2 FAIL=2 got PASS=$gp FAIL=$gf"
fi

# TC-4.2 / TC-4.3: file-not-found path emits "file not found" diagnostic
missing_state=$(bash -c "
  source '$HELPERS'
  assert_grep     'missing-grep'     '/nonexistent/path/xyz' 'pattern' 2>&1
  assert_not_grep 'missing-not-grep' '/nonexistent/path/xyz' 'pattern' 2>&1
  echo \"FAIL=\$FAIL\"
")
mfail=$(echo "$missing_state" | grep '^FAIL=' | cut -d= -f2)
if [ "$mfail" = "2" ]; then
  outer_pass "TC-4.2: file-not-found increments FAIL for both assert_grep and assert_not_grep"
else
  outer_fail "TC-4.2: expected FAIL=2 got FAIL=$mfail"
fi
if echo "$missing_state" | grep -q 'file not found'; then
  outer_pass "TC-4.3: file-not-found diagnostic message is emitted"
else
  outer_fail "TC-4.3: 'file not found' diagnostic missing in output"
fi

# === TC-5: print_summary return code ===
echo
echo "TC-5: print_summary return code"

# All-pass case → exit 0
if bash -c "source '$HELPERS'; pass 'x' >/dev/null; print_summary 'self-test' >/dev/null"; then
  outer_pass "TC-5.1: print_summary returns 0 when FAIL=0"
else
  outer_fail "TC-5.1: print_summary returned non-zero on all-pass"
fi

# Any-fail case → exit 1
if bash -c "source '$HELPERS'; fail 'x' >/dev/null; print_summary 'self-test' >/dev/null"; then
  outer_fail "TC-5.2: print_summary returned 0 on FAIL>0 (expected non-zero)"
else
  outer_pass "TC-5.2: print_summary returns non-zero when FAIL>0"
fi

# === TC-6: drift hint is echoed in summary ===
echo
echo "TC-6: print_summary drift hint propagation"

summary_output=$(bash -c "source '$HELPERS'; fail 'sample' >/dev/null; print_summary 'self-test' 'CUSTOM-DRIFT-HINT' || true")
if echo "$summary_output" | grep -q 'CUSTOM-DRIFT-HINT'; then
  outer_pass "TC-6.1: drift hint text appears in summary output"
else
  outer_fail "TC-6.1: drift hint not found in: $summary_output"
fi

# === Summary ===
echo
echo "─── $(basename "$0") summary ──────────────────────"
echo "PASS: $OUTER_PASS"
echo "FAIL: $OUTER_FAIL"

if [ "$OUTER_FAIL" -ne 0 ]; then
  echo "Failed assertions:"
  for n in "${OUTER_FAILED[@]}"; do
    echo "  - $n"
  done
  exit 1
fi
exit 0
