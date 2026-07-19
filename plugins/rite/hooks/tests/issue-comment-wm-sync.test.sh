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

extract_get_owner_repo() {
  awk '/^get_owner_repo\(\) \{/,/^\}$/' "$HOOK"
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

# ─── TC-005: init 冪等 pre-check → 既存 replica で二重投稿しない ────────
# init mode は投稿前に既存 replica を query し、存在すれば status=skipped;
# reason=already_exists で exit 0 する契約 (gh issue comment は実行されない)。
echo "TC-005: init idempotency — existing replica → status=skipped, no post"
dir005="$TEST_DIR/tc005"
mkdir -p "$dir005/bin"
echo '{"active":true,"issue_number":42}' > "$dir005/.rite-flow-state"
GH_SHIM_MARKER="$dir005/posted.marker"
cat > "$dir005/bin/gh" <<'GH_SHIM'
#!/bin/bash
case "$1 $2" in
  "repo view") echo "testowner/testrepo"; exit 0 ;;
  "api repos/testowner/testrepo/issues/42/comments") echo "111"; exit 0 ;;
  "issue comment") touch "$GH_SHIM_MARKER"; echo "https://github.com/testowner/testrepo/issues/42#issuecomment-1"; exit 0 ;;
esac
exit 0
GH_SHIM
chmod +x "$dir005/bin/gh"
out005=$(cd "$dir005" && PATH="$dir005/bin:$PATH" GH_SHIM_MARKER="$GH_SHIM_MARKER" \
  bash "$HOOK" init --issue 42 --branch "fix/issue-42-test" 2>/dev/null) || true
if printf '%s' "$out005" | grep -qF "status=skipped; reason=already_exists" && [ ! -f "$GH_SHIM_MARKER" ]; then
  pass "TC-005: existing replica → skipped; reason=already_exists, gh issue comment 未実行"
else
  fail "TC-005: expected skipped/already_exists without post. out: $out005 marker=$([ -f "$GH_SHIM_MARKER" ] && echo present || echo absent)"
fi
echo ""

# ─── TC-006: init — replica 不在なら投稿する (pre-check が正常経路を塞がない) ──
echo "TC-006: init posts when no replica exists"
dir006="$TEST_DIR/tc006"
mkdir -p "$dir006/bin"
echo '{"active":true,"issue_number":42}' > "$dir006/.rite-flow-state"
GH_SHIM_MARKER6="$dir006/posted.marker"
# pre-check は空を返し、投稿後の validation は id を返す (marker 存在で切替)
cat > "$dir006/bin/gh" <<'GH_SHIM'
#!/bin/bash
case "$1 $2" in
  "repo view") echo "testowner/testrepo"; exit 0 ;;
  "api repos/testowner/testrepo/issues/42/comments")
    if [ -f "$GH_SHIM_MARKER" ]; then echo "222"; fi
    exit 0 ;;
  "issue comment") touch "$GH_SHIM_MARKER"; echo "https://github.com/testowner/testrepo/issues/42#issuecomment-2"; exit 0 ;;
esac
exit 0
GH_SHIM
chmod +x "$dir006/bin/gh"
out006=$(cd "$dir006" && PATH="$dir006/bin:$PATH" GH_SHIM_MARKER="$GH_SHIM_MARKER6" \
  bash "$HOOK" init --issue 42 --branch "fix/issue-42-test" 2>/dev/null) || true
if printf '%s' "$out006" | grep -qF "status=success" && [ -f "$GH_SHIM_MARKER6" ]; then
  pass "TC-006: no replica → posted + status=success"
else
  fail "TC-006: expected post + status=success. out: $out006 marker=$([ -f "$GH_SHIM_MARKER6" ] && echo present || echo absent)"
fi
echo ""

# ─── TC-007: init pre-check gh api 失敗 → non-blocking degrade (WARNING + 投稿続行) ──
# pre-check の gh api 失敗は「存在不明」であり、ここで止めると replica が永遠に作られない
# 恐れがあるため rc 付き WARNING を出して投稿続行に倒す契約。TC-005/006 は正常経路のみで
# この degrade 経路は未検証だった (Issue #1844 D-05)。
echo "TC-007: init pre-check gh api failure → WARNING + posting continues"
dir007="$TEST_DIR/tc007"
mkdir -p "$dir007/bin"
echo '{"active":true,"issue_number":42}' > "$dir007/.rite-flow-state"
GH_SHIM_MARKER7="$dir007/posted.marker"
# pre-check (marker 不在) は gh api 失敗 (exit 1 + stderr)、投稿後の validation (marker 存在) は id を返す
cat > "$dir007/bin/gh" <<'GH_SHIM'
#!/bin/bash
case "$1 $2" in
  "repo view") echo "testowner/testrepo"; exit 0 ;;
  "api repos/testowner/testrepo/issues/42/comments")
    if [ -f "$GH_SHIM_MARKER" ]; then echo "333"; exit 0; fi
    echo "HTTP 500: Internal Server Error" >&2; exit 1 ;;
  "issue comment") touch "$GH_SHIM_MARKER"; echo "https://github.com/testowner/testrepo/issues/42#issuecomment-3"; exit 0 ;;
esac
exit 0
GH_SHIM
chmod +x "$dir007/bin/gh"
stderr007_file="$dir007/stderr.txt"
out007=$(cd "$dir007" && PATH="$dir007/bin:$PATH" GH_SHIM_MARKER="$GH_SHIM_MARKER7" \
  bash "$HOOK" init --issue 42 --branch "fix/issue-42-test" 2>"$stderr007_file") || true
stderr007=$(cat "$stderr007_file" 2>/dev/null)
if printf '%s' "$stderr007" | grep -qE 'init pre-check gh api 失敗 \(rc=1\)'; then
  pass "TC-007: pre-check failure WARNING carries real rc (1)"
else
  fail "TC-007: pre-check WARNING missing or rc collapsed. stderr: $stderr007"
fi
if printf '%s' "$stderr007" | grep -qF 'HTTP 500: Internal Server Error'; then
  pass "TC-007: captured gh stderr detail surfaced in WARNING"
else
  fail "TC-007: gh stderr detail not surfaced. stderr: $stderr007"
fi
if printf '%s' "$out007" | grep -qF "status=success" && [ -f "$GH_SHIM_MARKER7" ]; then
  pass "TC-007: posting continued despite pre-check failure → status=success"
else
  fail "TC-007: expected post-through + status=success. out: $out007 marker=$([ -f "$GH_SHIM_MARKER7" ] && echo present || echo absent)"
fi
echo ""

# ─── TC-008/009/010: get_owner_repo() (#1899) ────────────────────────────
# get_owner_repo() had zero caller-level or function-level coverage before
# this PR despite being the exact function cycle 2's review independently
# found a CRITICAL cwd-anchoring bug in. These 3 cases exercise the fast
# path's success case, its fall-through to the gh repo view fallback, and
# the both-fail WARNING path (a regression guard for the empty-stderr
# WARNING-header suppression bug fixed in this same PR: a `gh repo view`
# failure with empty stderr used to suppress the WARNING header itself).
func_get_owner_repo=$(extract_get_owner_repo)

echo "TC-008: get_owner_repo() fast path resolves via SSH Host alias origin, bypassing broken gh repo view"
dir008="$TEST_DIR/tc008"
mkdir -p "$dir008/bin"
( cd "$dir008" && git init -q && git remote add origin "git@github.com-work:o8/r8.git" )
cat > "$dir008/bin/gh" <<'GH_SHIM'
#!/bin/bash
case "$1 $2" in
  "repo view") echo "should not be called — git-remote should resolve first" >&2; exit 1 ;;
esac
exit 0
GH_SHIM
chmod +x "$dir008/bin/gh"
out008=$(cd "$dir008" && PATH="$dir008/bin:$PATH" bash -c "
  SCRIPT_DIR='$SCRIPT_DIR/..'
  STATE_ROOT='$dir008'
  source \"\$SCRIPT_DIR/control-char-neutralize.sh\"
  $func_get_owner_repo
  get_owner_repo
")
if [ "$out008" = "o8/r8" ]; then
  pass "TC-008: fast path resolved o8/r8 from alias origin, bypassing broken gh repo view"
else
  fail "TC-008: expected 'o8/r8', got '$out008'"
fi
echo ""

echo "TC-009: get_owner_repo() falls back to gh repo view when git-remote can't resolve"
dir009="$TEST_DIR/tc009"
mkdir -p "$dir009/bin" "$dir009/.git"
cat > "$dir009/bin/gh" <<'GH_SHIM'
#!/bin/bash
case "$1 $2" in
  "repo view") echo "o9/r9"; exit 0 ;;
esac
exit 0
GH_SHIM
chmod +x "$dir009/bin/gh"
out009=$(cd "$dir009" && PATH="$dir009/bin:$PATH" bash -c "
  SCRIPT_DIR='$SCRIPT_DIR/..'
  STATE_ROOT='$dir009'
  source \"\$SCRIPT_DIR/control-char-neutralize.sh\"
  $func_get_owner_repo
  get_owner_repo
")
if [ "$out009" = "o9/r9" ]; then
  pass "TC-009: fast path failure falls through to gh repo view fallback (o9/r9)"
else
  fail "TC-009: expected 'o9/r9', got '$out009'"
fi
echo ""

echo "TC-010: get_owner_repo() both fast path and fallback fail → WARNING header always emitted"
dir010="$TEST_DIR/tc010"
mkdir -p "$dir010/bin" "$dir010/.git"
cat > "$dir010/bin/gh" <<'GH_SHIM'
#!/bin/bash
case "$1 $2" in
  "repo view") exit 1 ;;
esac
exit 1
GH_SHIM
chmod +x "$dir010/bin/gh"
stderr010=$(cd "$dir010" && PATH="$dir010/bin:$PATH" bash -c "
  SCRIPT_DIR='$SCRIPT_DIR/..'
  STATE_ROOT='$dir010'
  source \"\$SCRIPT_DIR/control-char-neutralize.sh\"
  $func_get_owner_repo
  get_owner_repo
" 2>&1 >/dev/null)
if printf '%s' "$stderr010" | grep -qE 'WARNING: issue-comment-wm-sync: gh repo view failed'; then
  pass "TC-010: WARNING header emitted even when gh repo view fails with empty stderr"
else
  fail "TC-010: WARNING header missing when gh repo view fails silently. stderr: $stderr010"
fi
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
