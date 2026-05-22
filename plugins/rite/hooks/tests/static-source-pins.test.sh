#!/bin/bash
# Static-level regression guards that pin specific source-code patterns whose
# absence would silently re-introduce a known bug class. These are NOT runtime
# behavioural tests — they exist because the runtime test would still pass after
# the bug shape is reintroduced, leaving regression undetected until production.
#
# Pinned bug classes:
#   1. `if !` capture-and-read-rc antipattern in shell hooks. The bash `!`
#      operator zeros $? in its then-branch, so capturing rc via
#      `if ! var=$(cmd); then _rc=$?; ...` always shows 0 and hides the real
#      EXDEV/EACCES/SIGPIPE/parse-error rc from triagers.
#   2. pr/ready.md writing flat phase names (`ready` for success, `ready_error`
#      for failure). Reverting either to `pr` re-creates the resume-routing bug
#      that re-invokes `/rite:pr:create` against an already-existing PR.
#   3. Defense-in-depth comment references to the retired sub-skill-return
#      protocol must not resurface; the canonical layer model is the orchestrator
#      prose itself plus the caller HTML hint emitted by wiki/ingest.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

echo "=== Phase 1: if-not capture-and-read-rc antipattern absent in hooks ==="
# Two variants of the same antipattern:
#   Form A: `if ! var=$(cmd); then _rc=$?; ...`   (capture form)
#   Form B: `if ! cmd args...; then echo "...rc=$?"`   (direct-command form)
# Both leak: bash `!` flips status to 0/1 before $? is read, so any rc consulted
# inside the then-branch is the negated status — never the real EXDEV/EACCES/
# SIGPIPE/parse-error rc. Plain `if ! cmd; then echo "static WARNING"; fi`
# without `$?` is acceptable because it makes no rc claim.
#
# Detection: scan each file for `if ! <anything>` open, then in the matching
# then-branch (bounded by `^[[:space:]]*fi$`) look for any `$?` reference.
# Emits one fail() per violation with the line number.
#
# Files are enumerated dynamically from hooks/*.sh so a newly added hook is
# defended on day one without a manual allowlist update.
antipattern_files=()
while IFS= read -r f; do
  antipattern_files+=("$f")
done < <(find "$PLUGIN_ROOT/hooks" -maxdepth 1 -type f -name "*.sh" | sort)
if [ ${#antipattern_files[@]} -eq 0 ]; then
  fail "no hook scripts found under $PLUGIN_ROOT/hooks — enumeration broken"
fi
for f in "${antipattern_files[@]}"; do
  rel="${f#$PLUGIN_ROOT/}"
  violations=$(awk '
    /^[[:space:]]*if ![[:space:]]+/ {
      start_line=NR
      in_then=1
      next
    }
    in_then && /^[[:space:]]*fi[[:space:]]*$/ { in_then=0; next }
    in_then && /\$\?/ { print start_line ":" NR; in_then=0 }
  ' "$f")
  if [ -z "$violations" ]; then
    pass "no if-not read-\$?-after-bang antipattern in $rel"
  else
    fail "if-not read-\$?-after-bang antipattern present in \"$rel\" (start:rc_capture lines: $violations)"
  fi
done

echo ""
echo "=== Phase 2: pr/ready.md writes flat phase names ==="
READY_MD="$PLUGIN_ROOT/commands/pr/ready.md"
assert_file_exists_or_fail "pr/ready.md exists" "$READY_MD" || exit 1

# Success path: `--phase "ready"` and WM_PHASE="ready"
assert_grep "pr/ready.md success path patches --phase \"ready\" (flat)" \
  "$READY_MD" '^[[:space:]]*--phase[[:space:]]+"ready"[[:space:]]*\\?[[:space:]]*$'
assert_grep "pr/ready.md success path sets WM_PHASE=\"ready\"" \
  "$READY_MD" '^[[:space:]]*WM_PHASE="ready"[[:space:]]*\\?[[:space:]]*$'

# Failure path: `--phase "ready_error"`
assert_grep "pr/ready.md failure path patches --phase \"ready_error\" (flat)" \
  "$READY_MD" '^[[:space:]]*--phase[[:space:]]+"ready_error"[[:space:]]*\\?[[:space:]]*$'

# Negative: the previous-round bug shape `--phase "pr"` inside ready.md would
# route resume back to ステップ 6 (PR creation) — must not return.
assert_not_grep "pr/ready.md does NOT write --phase \"pr\" (would re-invoke /rite:pr:create)" \
  "$READY_MD" '^[[:space:]]*--phase[[:space:]]+"pr"[[:space:]]*\\?[[:space:]]*$'

# Legacy phase names must not return on the success path.
assert_not_grep "pr/ready.md does NOT write legacy phase5_post_ready" \
  "$READY_MD" '^[[:space:]]*--phase[[:space:]]+"phase5_post_ready"'
assert_not_grep "pr/ready.md does NOT write legacy phase5_ready" \
  "$READY_MD" '^[[:space:]]*--phase[[:space:]]+"phase5_ready"[[:space:]]*\\?'
assert_not_grep "pr/ready.md does NOT set legacy WM_PHASE=\"phase5_ready\"" \
  "$READY_MD" 'WM_PHASE="phase5_ready"'
assert_not_grep "pr/ready.md does NOT set legacy WM_PHASE=\"phase5_post_ready\"" \
  "$READY_MD" 'WM_PHASE="phase5_post_ready"'

echo ""
echo "=== Phase 3: retired sub-skill-return-protocol.md not cited as canonical ==="
# The retired file's own status header marks inbound references in these two
# files as stale. Defense-in-depth is now (1) orchestrator prose + (2) caller
# HTML hint emitted by wiki/ingest.md Phase 9.1.
assert_not_grep "cleanup.md does not cite retired sub-skill-return-protocol.md" \
  "$PLUGIN_ROOT/commands/pr/cleanup.md" 'sub-skill-return-protocol\.md'
assert_not_grep "wiki/ingest.md does not cite retired sub-skill-return-protocol.md" \
  "$PLUGIN_ROOT/commands/wiki/ingest.md" 'sub-skill-return-protocol\.md'

# Comment must not falsely list phase-transition-whitelist as an error_count
# reader — `error_count` is consulted only by orchestrator prose.
assert_not_grep "cleanup.md error_count rationale does not name phase-transition-whitelist as a reader" \
  "$PLUGIN_ROOT/commands/pr/cleanup.md" 'phase-transition-whitelist のエスカレーション判定の入力'
assert_not_grep "wiki/ingest.md error_count rationale does not name phase-transition-whitelist as a reader" \
  "$PLUGIN_ROOT/commands/wiki/ingest.md" 'phase-transition-whitelist の.*エスカレーション判定'

echo ""
echo "=== Phase 4: bang-backtick hook wired into init.md downstream sections ==="
# Round 7 added the hook to the detection table but missed the registration JSON
# template and chmod line. Pin all three sites so the next half-application is
# caught at test time.
INIT_MD="$PLUGIN_ROOT/commands/init.md"
assert_file_exists_or_fail "init.md exists" "$INIT_MD" || exit 1
assert_grep "init.md detection table lists bang-backtick (matcher Edit|Write|MultiEdit)" \
  "$INIT_MD" '`scripts/bang-backtick-edit-hook\.sh`'
assert_grep "init.md Configured hooks list has bang-backtick row" \
  "$INIT_MD" '\| PostToolUse \(Edit\\\|Write\\\|MultiEdit\) \|'
assert_grep "init.md JSON registration template includes Edit|Write|MultiEdit matcher" \
  "$INIT_MD" '"matcher": "Edit\|Write\|MultiEdit"'
assert_grep "init.md chmod line includes scripts/bang-backtick-edit-hook.sh" \
  "$INIT_MD" 'scripts/bang-backtick-edit-hook\.sh'

echo ""
echo "=== Phase 4b: check_session_ownership L173 WARNING is unconditional ==="
# The runtime path is rarely reachable (get_state_session_id parses the same
# file first), so the regression guard pins the source: the WARNING must not
# be wrapped in a RITE_DEBUG gate. If a future refactor hides this WARNING
# behind RITE_DEBUG, the cross-session overwrite race becomes silent.
SESSION_OWNERSHIP="$PLUGIN_ROOT/hooks/session-ownership.sh"
assert_file_exists_or_fail "session-ownership.sh exists" "$SESSION_OWNERSHIP" || exit 1
# Extract the check_session_ownership function body, then assert the WARNING
# at L180 is not preceded (within the function) by a `RITE_DEBUG` gate that
# would suppress the unconditional emit.
check_block=$(awk '/^check_session_ownership\(\) \{/,/^\}/' "$SESSION_OWNERSHIP")
if printf '%s' "$check_block" | grep -qE 'WARNING: check_session_ownership: jq parse failed'; then
  pass "check_session_ownership has the unconditional WARNING for corrupt updated_at"
else
  fail "check_session_ownership missing the WARNING — corrupt updated_at would silently fall through to 'stale' (cross-session overwrite race)"
fi
# Verify the WARNING line is not gated by `[ -n "$RITE_DEBUG" ] && ...` within
# the function. The stderr-snippet line that IS RITE_DEBUG-gated is the
# diagnostic dump (head -3 jq_err), not the WARNING itself.
warning_line=$(printf '%s' "$check_block" | awk '/WARNING: check_session_ownership: jq parse failed/ {print; exit}')
if printf '%s' "$warning_line" | grep -qE 'RITE_DEBUG'; then
  fail "check_session_ownership WARNING is RITE_DEBUG-gated — production WARNING must be unconditional"
else
  pass "check_session_ownership WARNING is unconditional (not RITE_DEBUG-gated)"
fi

echo ""
echo "=== Phase 5: session-ownership.sh callers do not suppress helper WARNINGs ==="
# extract_session_id / get_state_session_id emit WARNING unconditionally as
# production-safety signals. Caller-side `2>/dev/null` would silently drop them.
assert_not_grep "session-start.sh does not 2>/dev/null extract_session_id" \
  "$PLUGIN_ROOT/hooks/session-start.sh" 'extract_session_id "\$INPUT" 2>/dev/null'
assert_not_grep "flow-state-update.sh does not 2>/dev/null get_state_session_id" \
  "$PLUGIN_ROOT/hooks/flow-state-update.sh" 'get_state_session_id "\$FLOW_STATE" 2>/dev/null'

print_summary "$(basename "$0")"
