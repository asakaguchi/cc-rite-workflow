#!/bin/bash
# issue-comment-wm-sync.test.sh
#
# Pin the cache_comment_id mv-failure WARNING. A regression that reverts to the
# bash-! antipattern (`if ! mv; then _rc=$?`) would collapse rc to 0 and the
# WARNING would lie to triagers about why the cache is degrading.
#
# The hook's bottom-half is a CLI entrypoint that requires --issue/--mode, so
# rather than driving it end-to-end (which would also need gh api access), we
# extract the cache_comment_id function definition with awk and source only
# that. FLOW_STATE is set explicitly to the per-test path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../issue-comment-wm-sync.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

# Clean session-id env for standalone runs (same convention as
# cleanup-work-memory.test.sh / flow-state.test.sh). The FLOW_STATE resolver
# block under test (TC-003/TC-004) is env-first (CLAUDE_CODE_SESSION_ID /
# CLAUDE_SESSION_ID); without this unset, the dogfooding session's ambient
# session id would leak in and override each test's seeded .rite-session-id.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

extract_function() {
  awk '/^cache_comment_id\(\) \{/,/^\}$/' "$HOOK"
}

extract_resolver_block() {
  awk '/^# Resolve repository root for/,/^FLOW_STATE=/' "$HOOK"
}

echo "=== issue-comment-wm-sync.sh tests ==="
echo ""

# ─── TC-001: cache_comment_id mv failure → rc-carrying WARNING ───────────
echo "TC-001: cache_comment_id mv shim → WARNING carries real rc"
dir001="$TEST_DIR/tc001"
mkdir -p "$dir001/bin"
echo '{"active":true,"issue_number":42}' > "$dir001/.rite-flow-state"
cat > "$dir001/bin/mv" <<'MV_SHIM'
#!/bin/bash
exit 23
MV_SHIM
chmod +x "$dir001/bin/mv"

func_body=$(extract_function)
stderr001=$(PATH="$dir001/bin:$PATH" bash -c "
  FLOW_STATE='$dir001/.rite-flow-state'
  $func_body
  cache_comment_id 12345
" 2>&1 >/dev/null)
if printf '%s' "$stderr001" | grep -qE 'cache_comment_id mv failed \(rc=23'; then
  pass "TC-001: cache_comment_id mv WARNING carries real rc (23)"
else
  fail "TC-001: cache_comment_id WARNING missing or rc collapsed. stderr: $stderr001"
fi
echo ""

# ─── TC-002: cache_comment_id happy path → cid written, silent stderr ────
echo "TC-002: cache_comment_id happy path writes wm_comment_id"
dir002="$TEST_DIR/tc002"
mkdir -p "$dir002"
echo '{"active":true,"issue_number":42}' > "$dir002/.rite-flow-state"
stderr002=$(bash -c "
  FLOW_STATE='$dir002/.rite-flow-state'
  $func_body
  cache_comment_id 99999
" 2>&1 >/dev/null)
written_cid=$(jq -r '.wm_comment_id // empty' "$dir002/.rite-flow-state" 2>/dev/null)
if [ "$written_cid" = "99999" ]; then
  pass "TC-002: happy path wrote wm_comment_id=99999"
else
  fail "TC-002: wm_comment_id not written (got '$written_cid'). stderr: $stderr002"
fi
if printf '%s' "$stderr002" | grep -qE 'cache_comment_id (mv|jq) failed'; then
  fail "TC-002: happy path emitted a failure WARNING — stderr: $stderr002"
else
  pass "TC-002: happy path silent on stderr"
fi
echo ""

# ─── TC-003: FLOW_STATE resolver → resolves to per-session file (#1807) ──
# Regression guard for the fix to #1807: FLOW_STATE used to be hardcoded to
# the legacy shared path ($STATE_ROOT/.rite-flow-state), which does not exist
# in schema_v2/v3-only environments — every cache lookup missed and forced a
# full gh api comments scan. When a session_id is resolvable, FLOW_STATE must
# now point at the per-session file (.rite/sessions/{sid}.flow-state).
echo "TC-003: FLOW_STATE resolver resolves to per-session file when session_id is available"
dir003="$TEST_DIR/tc003"
mkdir -p "$dir003"
printf '%s' "tc003-sid" > "$dir003/.rite-session-id"
resolver_block=$(extract_resolver_block)
out003=$(cd "$dir003" && bash -c "
  SCRIPT_DIR='$SCRIPT_DIR/..'
  source \"\$SCRIPT_DIR/control-char-neutralize.sh\"
  CWD='$dir003'
  $resolver_block
  echo \"FLOW_STATE=\$FLOW_STATE\"
" 2>&1)
if printf '%s' "$out003" | grep -qF "FLOW_STATE=$dir003/.rite/sessions/tc003-sid.flow-state"; then
  pass "TC-003: resolver resolved to per-session file"
else
  fail "TC-003: resolver did not resolve to expected per-session path. got: $out003"
fi
echo ""

# ─── TC-004: FLOW_STATE resolver → falls back to legacy file with WARNING ──
# Regression guard for the fallback branch: when session_id cannot be
# resolved (no .rite-session-id / session env var), the resolver must emit a
# WARNING (not silently swallow the failure) and still fall back to the
# legacy shared path so callers keep a usable FLOW_STATE value.
echo "TC-004: FLOW_STATE resolver falls back to legacy path with WARNING when session_id unresolvable"
dir004="$TEST_DIR/tc004"
mkdir -p "$dir004"
out004=$(cd "$dir004" && bash -c "
  SCRIPT_DIR='$SCRIPT_DIR/..'
  source \"\$SCRIPT_DIR/control-char-neutralize.sh\"
  CWD='$dir004'
  $resolver_block
  echo \"FLOW_STATE=\$FLOW_STATE\"
" 2>&1)
if printf '%s' "$out004" | grep -q 'WARNING: issue-comment-wm-sync: flow-state.sh path resolution failed' && \
   printf '%s' "$out004" | grep -qE 'cannot resolve session_id' && \
   printf '%s' "$out004" | grep -qF "FLOW_STATE=$dir004/.rite-flow-state"; then
  pass "TC-004: resolver fallback emits WARNING and falls back to legacy path"
else
  fail "TC-004: expected WARNING + legacy fallback (with diagnostic detail). got: $out004"
fi
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
