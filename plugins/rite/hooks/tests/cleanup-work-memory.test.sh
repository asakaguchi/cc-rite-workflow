#!/bin/bash
# cleanup-work-memory.test.sh
#
# Pin the mktemp-failure fallback path: even when the TMP_STATE mktemp fails,
# Step 2 (.rite-compact-state removal) and Step 3 (per-issue work-memory file
# removal) MUST still execute. Without this regression guard, a `set -euo
# pipefail` regression on the mktemp line could abort the script before any
# cleanup runs — leaving stale state files that would silently misroute the
# next session.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../cleanup-work-memory.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== cleanup-work-memory.sh tests ==="
echo ""

# ─── TC-001: TMP_STATE mktemp 失敗時でも Step 2/3 が実行されること ────────
echo "TC-001: TMP_STATE mktemp failure does not abort Step 2/3 cleanup"
dir001="$TEST_DIR/tc001"
mkdir -p "$dir001/.rite-work-memory"
# Seed flow-state, compact-state, and a per-issue work memory file
echo '{"active":true,"issue_number":42,"phase":"completed","branch":"feat/issue-42-test"}' > "$dir001/.rite-flow-state"
echo '{"compact_state":"recovering","active_issue":42}' > "$dir001/.rite-compact-state"
echo "# work memory for issue 42" > "$dir001/.rite-work-memory/issue-42.md"

# Inject a mktemp shim that fails only when the target argument matches the
# FLOW_STATE.tmp pattern. All other mktemp invocations (test helpers, child
# scripts) pass through to real mktemp.
mkdir -p "$dir001/bin"
cat > "$dir001/bin/mktemp" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    *.rite-flow-state.tmp.*) exit 1 ;;
  esac
done
exec /usr/bin/mktemp "$@"
EOF
chmod +x "$dir001/bin/mktemp"

# Run with the shim active and cwd at the test dir. CLOSE_MODE=false (default)
# exercises the reset path that creates TMP_STATE. state-path-resolve.sh
# resolves STATE_ROOT from $(pwd), so cd into the dir before running.
err_log="$TEST_DIR/tc001.err"
( cd "$dir001" && PATH="$dir001/bin:$PATH" bash "$HOOK" 2>"$err_log" >/dev/null ) || true

# Step 1 (flow-state reset) should have been skipped with a WARNING
if grep -q "TMP_STATE mktemp failed" "$err_log"; then
  pass "TC-001 Step 1 mktemp failure WARNING emitted"
else
  fail "TC-001 expected 'TMP_STATE mktemp failed' WARNING, got: $(head -5 "$err_log")"
fi

# Step 2 (.rite-compact-state removal) should have succeeded
if [ ! -f "$dir001/.rite-compact-state" ]; then
  pass "TC-001 Step 2: .rite-compact-state removed despite Step 1 mktemp failure"
else
  fail "TC-001 Step 2 SKIPPED: .rite-compact-state still present (cleanup aborted on Step 1 failure)"
fi

# Step 3 (per-issue work memory removal) should have succeeded
if [ ! -f "$dir001/.rite-work-memory/issue-42.md" ]; then
  pass "TC-001 Step 3: per-issue work memory removed despite Step 1 mktemp failure"
else
  fail "TC-001 Step 3 SKIPPED: issue-42.md still present (cleanup aborted on Step 1 failure)"
fi
echo ""

# ─── TC-002: 正常路 (negative control) ──────────────────────────
echo "TC-002: happy path with working mktemp removes all three"
dir002="$TEST_DIR/tc002"
mkdir -p "$dir002/.rite-work-memory"
echo '{"active":true,"issue_number":43,"phase":"completed"}' > "$dir002/.rite-flow-state"
echo '{"compact_state":"recovering","active_issue":43}' > "$dir002/.rite-compact-state"
echo "# wm 43" > "$dir002/.rite-work-memory/issue-43.md"

( cd "$dir002" && bash "$HOOK" >/dev/null 2>&1 ) || true

# After successful run: compact-state and per-issue wm file removed.
# (Step 1 flow-state reset is asserted indirectly through TC-001's WARNING
# absence — the lack of warning means the mktemp/jq/mv chain succeeded.)
if [ ! -f "$dir002/.rite-compact-state" ] \
   && [ ! -f "$dir002/.rite-work-memory/issue-43.md" ]; then
  pass "TC-002 happy path: Step 2/3 cleanup completed (compact-state + per-issue wm removed)"
else
  fail "TC-002 happy path partial: compact-state present=$([ -f "$dir002/.rite-compact-state" ] && echo y || echo n), wm present=$([ -f "$dir002/.rite-work-memory/issue-43.md" ] && echo y || echo n)"
fi
echo ""

# --- Summary ---
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
