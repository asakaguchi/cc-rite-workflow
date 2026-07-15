#!/bin/bash
# Tests for pre-tool-bash-guard.sh (PreToolUse hook)
# Usage: bash plugins/rite/hooks/tests/pre-tool-bash-guard.test.sh
set -euo pipefail

# Tier 3 (env var) subagent detection を導入したため、host 環境に
# CLAUDE_SUBAGENT_TYPE / CLAUDE_AGENT_TYPE が export されていると既存の
# main-session allow テスト (TC-022 stderr branch / TC-023 / TC-028 / TC-062 等) が
# Tier 3 経路で誤って deny 判定され flake する。全テストで一律遮断する。
unset CLAUDE_SUBAGENT_TYPE CLAUDE_AGENT_TYPE

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../pre-tool-bash-guard.sh"
PASS=0
FAIL=0
STDERR_FILE=$(mktemp)

cleanup() {
  rm -f "$STDERR_FILE"
}
trap cleanup EXIT

# Prerequisite check: jq is required
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

pass() {
  PASS=$((PASS + 1))
  echo "  ✅ PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  ❌ FAIL: $1"
}

# Helper: run hook with given tool_name and command
# Captures stderr to $STDERR_FILE for log verification
run_guard() {
  local tool_name="$1"
  local cmd="$2"
  local rc=0
  local output
  output=$(jq -n --arg tn "$tool_name" --arg cmd "$cmd" \
    '{tool_name: $tn, tool_input: {command: $cmd}, cwd: "/tmp"}' \
    | bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

# Helper: run hook with raw JSON input (for malformed input testing)
run_guard_raw() {
  local raw_input="$1"
  local rc=0
  local output
  output=$(echo "$raw_input" | bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

# Helper: run hook with an explicit transcript_path (reviewer subagent tests)
# Pattern 4 only activates when transcript_path contains "/subagents/".
run_guard_with_transcript() {
  local tool_name="$1"
  local cmd="$2"
  local transcript="$3"
  local rc=0
  local output
  output=$(jq -n --arg tn "$tool_name" --arg cmd "$cmd" --arg tp "$transcript" \
    '{tool_name: $tn, tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}' \
    | bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

echo "=== pre-tool-bash-guard.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-001: gh pr diff --stat → deny
# --------------------------------------------------------------------------
echo "TC-001: gh pr diff --stat → deny (with stderr log)"
rc=0
output=$(run_guard "Bash" "gh pr diff 123 --stat") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
stderr_log=$(cat "$STDERR_FILE")
if [ "$decision" = "deny" ] && [[ "$reason" == *"gh-pr-diff-stat"* ]]; then
  pass "gh pr diff --stat blocked with correct pattern name"
else
  fail "Expected deny with gh-pr-diff-stat, got decision=$decision reason=$reason"
fi
if [[ "$stderr_log" == *"bash-guard: BLOCKED"* ]] && [[ "$stderr_log" == *"gh-pr-diff-stat"* ]]; then
  pass "stderr contains block log with pattern name"
else
  fail "Expected stderr block log, got: $stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# TC-002: gh pr diff -- <path> → deny
# --------------------------------------------------------------------------
echo "TC-002: gh pr diff -- <path> → deny"
rc=0
output=$(run_guard "Bash" "gh pr diff 456 -- path/to/file.md") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"gh-pr-diff-file-filter"* ]]; then
  pass "gh pr diff -- <path> blocked with correct pattern name"
else
  fail "Expected deny with gh-pr-diff-file-filter, got decision=$decision reason=$reason"
fi
echo ""

# --------------------------------------------------------------------------
# TC-003: != null in jq → deny
# --------------------------------------------------------------------------
echo "TC-003: != null in jq → deny"
rc=0
output=$(run_guard "Bash" "gh api repos/owner/repo/issues --jq '.[] | select(.field != null)'") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"jq-not-equal-null"* ]]; then
  pass "!= null blocked with correct pattern name"
else
  fail "Expected deny with jq-not-equal-null, got decision=$decision reason=$reason"
fi
echo ""

# --------------------------------------------------------------------------
# TC-004: Safe gh pr diff → allow
# --------------------------------------------------------------------------
echo "TC-004: Safe gh pr diff → allow"
rc=0
output=$(run_guard "Bash" "gh pr diff 123") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "gh pr diff (no flags) allowed"
else
  fail "Expected allow (exit 0, no output), got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-005: Non-Bash tool → allow
# --------------------------------------------------------------------------
echo "TC-005: Non-Bash tool → allow"
rc=0
output=$(run_guard "Read" "anything") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "Non-Bash tool allowed"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-006: Safe jq with select(.field) → allow
# --------------------------------------------------------------------------
echo "TC-006: Safe jq select(.field) → allow"
rc=0
output=$(run_guard "Bash" "gh api repos/owner/repo/issues --jq '.[] | select(.field)'") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "select(.field) allowed"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-007: gh pr view --json files (safe alternative) → allow
# --------------------------------------------------------------------------
echo "TC-007: gh pr view --json files → allow"
rc=0
output=$(run_guard "Bash" "gh pr view 123 --json files --jq '.files[] | {path, additions, deletions}'") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "gh pr view --json files allowed"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-008: gh pr diff --name-only (safe) → allow
# --------------------------------------------------------------------------
echo "TC-008: gh pr diff --name-only → allow"
rc=0
output=$(run_guard "Bash" "gh pr diff 123 --name-only") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "gh pr diff --name-only allowed"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-009: gh pr diff piped to awk (safe) → allow
# --------------------------------------------------------------------------
echo "TC-009: gh pr diff | awk → allow"
rc=0
output=$(run_guard "Bash" "gh pr diff 123 | awk '/^diff --git/ { found=0 } /target/ { found=1 } found { print }'") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "gh pr diff | awk allowed"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-010: Empty command → allow
# --------------------------------------------------------------------------
echo "TC-010: Empty command → allow"
rc=0
output=$(run_guard "Bash" "") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "Empty command allowed"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-011: Deny JSON structure validation (Pattern 2: -- <path>)
# --------------------------------------------------------------------------
echo "TC-011: Deny JSON has all required fields (Pattern 2)"
rc=0
output=$(run_guard "Bash" "gh pr diff 99 -- src/file.ts") || rc=$?
HAS_EVENT=$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)
HAS_DECISION=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
HAS_REASON=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$HAS_EVENT" = "PreToolUse" ] && \
   [ "$HAS_DECISION" = "deny" ] && \
   [ -n "$HAS_REASON" ]; then
  pass "Deny JSON has all required fields (Pattern 2: gh-pr-diff-file-filter)"
else
  fail "Missing fields: event=$HAS_EVENT decision=$HAS_DECISION reason=$HAS_REASON"
fi
echo ""

# --------------------------------------------------------------------------
# TC-012: Heredoc content should not trigger false positive
# --------------------------------------------------------------------------
echo "TC-012: Pattern inside heredoc → allow (no false positive)"
rc=0
HEREDOC_CMD='git commit -m "$(cat <<'"'"'EOF'"'"'
gh pr diff --stat is not supported
EOF
)"'
output=$(run_guard "Bash" "$HEREDOC_CMD") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "Pattern inside heredoc allowed (no false positive)"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-013: Pattern inside heredoc with != null → allow
# --------------------------------------------------------------------------
echo "TC-013: != null inside heredoc → allow (no false positive)"
rc=0
HEREDOC_CMD2='git commit -m "$(cat <<'"'"'EOF'"'"'
select(.field != null) is prohibited
EOF
)"'
output=$(run_guard "Bash" "$HEREDOC_CMD2") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "!= null inside heredoc allowed (no false positive)"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-014: !=null (no space) in jq → deny
# --------------------------------------------------------------------------
echo "TC-014: !=null (no space) → deny"
rc=0
output=$(run_guard "Bash" "gh api repos/owner/repo/issues --jq '.[] | select(.field !=null)'") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"jq-not-equal-null"* ]]; then
  pass "!=null (no space) blocked with correct pattern name"
else
  fail "Expected deny with jq-not-equal-null, got decision=$decision reason=$reason"
fi
echo ""

# --------------------------------------------------------------------------
# TC-015: gh pr diff --color (safe flag) → allow
# --------------------------------------------------------------------------
echo "TC-015: gh pr diff --color → allow"
rc=0
output=$(run_guard "Bash" "gh pr diff 123 --color") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "gh pr diff --color allowed (not confused with --stat)"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-016: Malformed JSON input → exit 0 (fail-open: jq fallback handles it)
# Note: Since commit 84160bd added `|| TOOL_NAME=""` fallback, malformed JSON
# results in TOOL_NAME="" → exit 0 (allow). This is correct fail-open behavior.
# --------------------------------------------------------------------------
echo "TC-016: Malformed JSON input → exit 0 (fail-open via jq fallback)"
rc=0
output=$(run_guard_raw "not valid json at all") || rc=$?
if [ "$rc" = "0" ]; then
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  if [ -z "$decision" ]; then
    pass "Malformed JSON → exit 0, no deny output (fail-open via || TOOL_NAME=\"\" fallback)"
  else
    fail "Malformed JSON should not produce deny, got decision=$decision"
  fi
else
  fail "Expected exit 0 for malformed JSON (fail-open), got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-017: JSON missing tool_input field → allow
# --------------------------------------------------------------------------
echo "TC-017: JSON missing tool_input → allow"
rc=0
output=$(run_guard_raw '{"tool_name": "Bash"}') || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "Missing tool_input allowed (empty command path)"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-018: Deny stderr includes command summary (Pattern 3: != null)
# --------------------------------------------------------------------------
echo "TC-018: Deny stderr log includes command summary (Pattern 3)"
rc=0
output=$(run_guard "Bash" "gh api repos/o/r --jq '.[] | select(.x != null)'") || rc=$?
stderr_log=$(cat "$STDERR_FILE")
if [[ "$stderr_log" == *'cmd="'* ]] && [[ "$stderr_log" == *"jq-not-equal-null"* ]]; then
  pass "stderr log includes cmd= field and correct pattern name (Pattern 3)"
else
  fail "Expected cmd= and jq-not-equal-null in stderr log, got: $stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# TC-019: Pattern 2 with multiple spaces → deny
# --------------------------------------------------------------------------
echo "TC-019: gh  pr  diff  123  -- file (multi-space) → deny"
rc=0
output=$(run_guard "Bash" "gh  pr  diff  123  -- file.md") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [ "$decision" = "deny" ]; then
  pass "Multi-space Pattern 2 blocked"
else
  fail "Expected deny for multi-space Pattern 2, got decision=$decision"
fi
echo ""

# --------------------------------------------------------------------------
# TC-020: Overlapping patterns → first match wins (Pattern 1 priority)
# --------------------------------------------------------------------------
echo "TC-020: gh pr diff --stat -- file → deny with gh-pr-diff-stat (priority)"
rc=0
output=$(run_guard "Bash" "gh pr diff 123 --stat -- file.md") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"gh-pr-diff-stat"* ]]; then
  pass "Overlapping patterns: Pattern 1 (--stat) takes priority"
else
  fail "Expected deny with gh-pr-diff-stat, got decision=$decision reason=$reason"
fi
echo ""

# --------------------------------------------------------------------------
# TC-021: Multiline command with blocked pattern → deny
# --------------------------------------------------------------------------
echo "TC-021: Multiline command with --stat → deny"
rc=0
MULTILINE_CMD=$(printf 'gh pr diff 123 \\\n  --stat')
output=$(run_guard "Bash" "$MULTILINE_CMD") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
# bash case glob * matches across newlines, so deny is the expected result
if [ "$decision" = "deny" ]; then
  pass "Multiline: glob * matches across newlines"
else
  fail "Expected deny for multiline command, got decision=$decision"
fi
echo ""

# --------------------------------------------------------------------------
# Pattern 4: Reviewer subagent state-mutating git denylist
#
# Scope: Only when transcript_path contains "/subagents/".
# Main session git operations must continue to work.
# --------------------------------------------------------------------------

SUBAGENT_TRANSCRIPT="/home/user/.claude/projects/proj/session-id/subagents/agent-abc123.jsonl"
MAIN_TRANSCRIPT="/home/user/.claude/projects/proj/session-id/main.jsonl"

# --------------------------------------------------------------------------
# TC-022: Reviewer subagent + git checkout <ref> -- <file> → deny
# --------------------------------------------------------------------------
echo "TC-022: reviewer subagent + 'git checkout develop -- file' → deny"
rc=0
output=$(run_guard_with_transcript "Bash" "git checkout develop -- plugins/rite/hooks/pre-tool-bash-guard.sh" "$SUBAGENT_TRANSCRIPT") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
stderr_log=$(cat "$STDERR_FILE")
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-state-mutating-git"* ]]; then
  pass "reviewer subagent 'git checkout -- file' blocked"
else
  fail "Expected deny with reviewer-state-mutating-git, got decision=$decision reason=$reason"
fi
if [[ "$stderr_log" == *"reviewer-state-mutating-git"* ]]; then
  pass "stderr log recorded reviewer-state-mutating-git pattern name"
else
  fail "Expected reviewer-state-mutating-git in stderr, got: $stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# TC-023: Main session + git checkout <branch> → allow (non-regression)
# Phase 5.1 implement flow MUST NOT be blocked.
# --------------------------------------------------------------------------
echo "TC-023: main session + 'git checkout develop' → allow (non-regression)"
rc=0
output=$(run_guard_with_transcript "Bash" "git checkout develop" "$MAIN_TRANSCRIPT") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "main session git checkout allowed (not a subagent)"
else
  fail "Expected allow for main session git checkout, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-024: Reviewer subagent + git diff → allow (read-only)
# --------------------------------------------------------------------------
echo "TC-024: reviewer subagent + 'git diff' → allow (read-only)"
rc=0
output=$(run_guard_with_transcript "Bash" "git diff develop..HEAD -- plugins/rite/agents/_reviewer-base.md" "$SUBAGENT_TRANSCRIPT") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "reviewer subagent git diff allowed"
else
  fail "Expected allow for reviewer git diff, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-025: Reviewer subagent + git show <ref>:<file> → allow (read-only)
# This is the documented alternative to 'git checkout <ref> -- <file>'.
# --------------------------------------------------------------------------
echo "TC-025: reviewer subagent + 'git show <ref>:<file>' → allow"
rc=0
output=$(run_guard_with_transcript "Bash" "git show develop:plugins/rite/agents/_reviewer-base.md" "$SUBAGENT_TRANSCRIPT") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "reviewer subagent git show allowed (read-only alternative)"
else
  fail "Expected allow for reviewer git show, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-026: Reviewer subagent + git reset → deny
# --------------------------------------------------------------------------
echo "TC-026: reviewer subagent + 'git reset' → deny"
rc=0
output=$(run_guard_with_transcript "Bash" "git reset --hard HEAD" "$SUBAGENT_TRANSCRIPT") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-state-mutating-git"* ]]; then
  pass "reviewer subagent git reset blocked with correct pattern name"
else
  fail "Expected deny with reviewer-state-mutating-git for git reset, got decision=$decision reason=$reason"
fi
echo ""

# --------------------------------------------------------------------------
# TC-027: Reviewer subagent + git stash → deny
# --------------------------------------------------------------------------
echo "TC-027: reviewer subagent + 'git stash push' → deny"
rc=0
output=$(run_guard_with_transcript "Bash" "git stash push -m 'wip'" "$SUBAGENT_TRANSCRIPT") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-state-mutating-git"* ]]; then
  pass "reviewer subagent git stash push blocked with correct pattern name"
else
  fail "Expected deny with reviewer-state-mutating-git for git stash push, got decision=$decision reason=$reason"
fi
echo ""

# --------------------------------------------------------------------------
# TC-028: Main session + git reset → allow (non-regression)
# The /rite:fix flow in the main session may use git reset legitimately.
# --------------------------------------------------------------------------
echo "TC-028: main session + 'git reset' → allow (non-regression)"
rc=0
output=$(run_guard_with_transcript "Bash" "git reset HEAD~1" "$MAIN_TRANSCRIPT") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "main session git reset allowed"
else
  fail "Expected allow for main session git reset, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-029: Reviewer subagent + gh pr diff → allow (workflow operation)
# --------------------------------------------------------------------------
echo "TC-029: reviewer subagent + 'gh pr diff 123' → allow"
rc=0
output=$(run_guard_with_transcript "Bash" "gh pr diff 123" "$SUBAGENT_TRANSCRIPT") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "reviewer subagent gh pr diff allowed"
else
  fail "Expected allow for reviewer gh pr diff, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-030: Reviewer subagent + bash test runner → allow (workflow operation)
# --------------------------------------------------------------------------
echo "TC-030: reviewer subagent + 'bash test.sh' → allow"
rc=0
output=$(run_guard_with_transcript "Bash" "bash plugins/rite/hooks/tests/pre-tool-bash-guard.test.sh" "$SUBAGENT_TRANSCRIPT") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "reviewer subagent bash test allowed"
else
  fail "Expected allow for reviewer bash test, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-031: Reviewer subagent + git worktree add → allow (isolated inspection)
# --------------------------------------------------------------------------
echo "TC-031: reviewer subagent + 'git worktree add' → allow"
rc=0
output=$(run_guard_with_transcript "Bash" "git worktree add /tmp/rite-review-wt develop" "$SUBAGENT_TRANSCRIPT") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "reviewer subagent git worktree add allowed"
else
  fail "Expected allow for reviewer git worktree add, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-032: Reviewer subagent + git worktree remove → deny
# --------------------------------------------------------------------------
echo "TC-032: reviewer subagent + 'git worktree remove' → deny"
rc=0
output=$(run_guard_with_transcript "Bash" "git worktree remove /tmp/rite-review-wt" "$SUBAGENT_TRANSCRIPT") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-state-mutating-git"* ]]; then
  pass "reviewer subagent git worktree remove blocked with correct pattern name"
else
  fail "Expected deny with reviewer-state-mutating-git for git worktree remove, got decision=$decision reason=$reason"
fi
echo ""

# --------------------------------------------------------------------------
# TC-033: Reviewer subagent + heredoc containing 'git checkout' → allow (false positive guard)
# --------------------------------------------------------------------------
echo "TC-033: reviewer subagent + heredoc text containing 'git checkout' → allow"
rc=0
HEREDOC_CMD3='cat <<'"'"'EOF'"'"'
git checkout develop -- file.md
EOF'
output=$(run_guard_with_transcript "Bash" "$HEREDOC_CMD3" "$SUBAGENT_TRANSCRIPT") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "heredoc text 'git checkout' allowed (no false positive)"
else
  fail "Expected allow for heredoc text, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# Pattern 4 Cycle 2 additions
#
# Coverage expansion: every always-deny verb, bypass path, and read-only
# sub-command that stays allowed.
# --------------------------------------------------------------------------

# --- Helper: deny assertion with stderr/reason validation ---
assert_subagent_deny() {
  local label="$1"
  local cmd="$2"
  local rc=0
  local output
  output=$(run_guard_with_transcript "Bash" "$cmd" "$SUBAGENT_TRANSCRIPT") || rc=$?
  local decision
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  local reason
  reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
  if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-state-mutating-git"* ]]; then
    pass "$label"
  else
    fail "$label — expected deny (reviewer-state-mutating-git), got decision=$decision reason=$reason"
  fi
}

# --- Helper: allow assertion (subagent) ---
assert_subagent_allow() {
  local label="$1"
  local cmd="$2"
  local rc=0
  local output
  output=$(run_guard_with_transcript "Bash" "$cmd" "$SUBAGENT_TRANSCRIPT") || rc=$?
  if [ "$rc" = "0" ] && [ -z "$output" ]; then
    pass "$label"
  else
    fail "$label — expected allow, got rc=$rc output=$output"
  fi
}

# --- Helper: allow assertion (main session) ---
assert_main_allow() {
  local label="$1"
  local cmd="$2"
  local rc=0
  local output
  output=$(run_guard_with_transcript "Bash" "$cmd" "$MAIN_TRANSCRIPT") || rc=$?
  if [ "$rc" = "0" ] && [ -z "$output" ]; then
    pass "$label"
  else
    fail "$label — expected allow, got rc=$rc output=$output"
  fi
}

# --------------------------------------------------------------------------
# TC-034〜042: Always-deny verbs coverage (denylist 主要カテゴリを網羅)
# --------------------------------------------------------------------------
echo "TC-034: subagent + git add → deny"
assert_subagent_deny "subagent git add . blocked" "git add ."

echo "TC-035: subagent + git commit → deny"
assert_subagent_deny "subagent git commit blocked" "git commit -am 'wip'"

echo "TC-036: subagent + git push → deny"
assert_subagent_deny "subagent git push blocked" "git push origin feat/foo"

echo "TC-037: subagent + git merge → deny"
assert_subagent_deny "subagent git merge blocked" "git merge develop"

echo "TC-038: subagent + git rebase → deny"
assert_subagent_deny "subagent git rebase blocked" "git rebase -i HEAD~3"

echo "TC-039: subagent + git cherry-pick → deny"
assert_subagent_deny "subagent git cherry-pick blocked" "git cherry-pick abc1234"

echo "TC-040: subagent + git revert → deny"
assert_subagent_deny "subagent git revert blocked" "git revert abc1234"

echo "TC-041: subagent + git restore → deny"
assert_subagent_deny "subagent git restore blocked" "git restore --source=HEAD file.md"

echo "TC-042: subagent + git update-ref → deny"
assert_subagent_deny "subagent git update-ref blocked" "git update-ref refs/heads/foo abc1234"

# --------------------------------------------------------------------------
# TC-043〜047: Shell meta-char boundary bypass prevention
# --------------------------------------------------------------------------
echo "TC-043: subagent + semicolon-chained 'true;git reset' → deny"
assert_subagent_deny "shell boundary ;git reset blocked" "true;git reset --hard HEAD"

echo "TC-044: subagent + AND-chained '&&git checkout' → deny"
assert_subagent_deny "shell boundary &&git checkout blocked" "cd /tmp&&git checkout develop -- file"

echo "TC-045: subagent + command-substitution '\$(git commit)' → deny"
assert_subagent_deny "shell boundary \$(git commit) blocked" "result=\$(git commit -am wip)"

echo "TC-046: subagent + subshell '(git reset)' → deny"
assert_subagent_deny "shell boundary (git reset) blocked" "(git reset --hard HEAD)"

echo "TC-047: subagent + backtick \`git push\` → deny"
assert_subagent_deny "shell boundary backtick git push blocked" "echo \`git push origin feat/foo\`"

# --------------------------------------------------------------------------
# TC-048〜053: Read-only sub-command false positive prevention
# (git tag -l / git stash list / git reflog / git worktree list / git branch --list)
# --------------------------------------------------------------------------
echo "TC-048: subagent + 'git tag -l v1.*' → allow (read-only list)"
assert_subagent_allow "subagent git tag -l allowed" "git tag -l 'v1.*'"

echo "TC-049: subagent + 'git tag --list' → allow"
assert_subagent_allow "subagent git tag --list allowed" "git tag --list"

echo "TC-050: subagent + 'git stash list' → allow (read-only)"
assert_subagent_allow "subagent git stash list allowed" "git stash list"

echo "TC-051: subagent + 'git stash show stash@{0}' → allow (read-only)"
assert_subagent_allow "subagent git stash show allowed" "git stash show stash@{0}"

echo "TC-052: subagent + 'git reflog' (bare) → allow (read-only display)"
assert_subagent_allow "subagent bare git reflog allowed" "git reflog"

echo "TC-053: subagent + 'git worktree list' → allow (read-only)"
assert_subagent_allow "subagent git worktree list allowed" "git worktree list"

# --------------------------------------------------------------------------
# TC-054〜057: git branch coverage (display allowed, mutations denied)
# --------------------------------------------------------------------------
echo "TC-054: subagent + bare 'git branch' → allow (list display)"
assert_subagent_allow "subagent bare git branch allowed" "git branch"

echo "TC-055: subagent + 'git branch --list' → allow"
assert_subagent_allow "subagent git branch --list allowed" "git branch --list"

echo "TC-056: subagent + 'git branch -a' → allow (display all)"
assert_subagent_allow "subagent git branch -a allowed" "git branch -a"

echo "TC-057a: subagent + 'git branch feature/foo' (bare new branch) → deny"
assert_subagent_deny "subagent bare new branch creation blocked" "git branch feature/foo"

echo "TC-057b: subagent + 'git branch --delete feature/foo' (long-form) → deny"
assert_subagent_deny "subagent git branch --delete blocked" "git branch --delete feature/foo"

echo "TC-057c: subagent + 'git branch --force feat' → deny"
assert_subagent_deny "subagent git branch --force blocked" "git branch --force feat"

# --------------------------------------------------------------------------
# TC-057d〜057h: git worktree add new-ref-leak forms denied,
# proper --detach / existing-branch forms allowed.
# 既存 (E) では `git worktree remove/prune` のみ block していたため、reviewer が
# `git worktree add -b <newbranch>` 経由で新規 named branch を leak できた gap を補完。
# --------------------------------------------------------------------------
echo "TC-057d: subagent + 'git worktree add -b pr-994-test /tmp/d HEAD' → deny (new branch leak)"
assert_subagent_deny "subagent worktree add -b new-branch blocked" \
  "git worktree add -b pr-994-test /tmp/d HEAD"

echo "TC-057e: subagent + 'git worktree add --new-branch foo /tmp/d HEAD' → deny (long-form)"
assert_subagent_deny "subagent worktree add --new-branch blocked" \
  "git worktree add --new-branch foo /tmp/d HEAD"

echo "TC-057f: subagent + 'git worktree add /tmp/d' (1 positional, auto-creates branch) → deny"
assert_subagent_deny "subagent bare worktree add (auto-branch) blocked" \
  "git worktree add /tmp/d"

echo "TC-057g: subagent + 'git worktree add --detach /tmp/d HEAD' → allow (no ref leak)"
assert_subagent_allow "subagent worktree add --detach allowed" \
  "git worktree add --detach /tmp/d HEAD"

echo "TC-057h: subagent + 'git worktree add /tmp/d develop' (existing branch) → allow"
assert_subagent_allow "subagent worktree add existing-branch allowed" \
  "git worktree add /tmp/d develop"

echo "TC-057i: subagent + 'git worktree move /tmp/a /tmp/b' → deny"
assert_subagent_deny "subagent worktree move blocked" \
  "git worktree move /tmp/a /tmp/b"

# --------------------------------------------------------------------------
# TC-057j: reproduction — git checkout -b <new-branch> from subagent
# Pattern (A) Always-deny の deny verb `git checkout` で block されることを期待
# (Pattern (E) ではない)。reason 文字列に `reviewer-state-mutating-git` が含まれる
# ことは assert_subagent_deny helper が確認する。
# --------------------------------------------------------------------------
echo "TC-057j: subagent + 'git checkout -b pr-994-test' (reproduction) → deny"
assert_subagent_deny "subagent git checkout -b new-branch blocked" \
  "git checkout -b pr-994-test"

# --------------------------------------------------------------------------
# TC-057k〜057p: Pattern (E) bypass 経路の cycle 1 fix
# (test-reviewer / security-reviewer 指摘で実機検証された bypass 経路)
# --------------------------------------------------------------------------

# -b attached form (no space): `-bNAME`
echo "TC-057k: subagent + 'git worktree add -bpr-994-test /tmp/d HEAD' → deny (attached, no space)"
assert_subagent_deny "subagent worktree add -bNAME (no space) blocked" \
  "git worktree add -bpr-994-test /tmp/d HEAD"

# -b attached form with `=`: `-b=NAME`
echo "TC-057l: subagent + 'git worktree add -b=evil /tmp/d HEAD' → deny (attached '=' form)"
assert_subagent_deny "subagent worktree add -b=NAME (attached =) blocked" \
  "git worktree add -b=evil /tmp/d HEAD"

# --new-branch=NAME (long-form attached)
echo "TC-057m: subagent + 'git worktree add --new-branch=evil /tmp/d HEAD' → deny"
assert_subagent_deny "subagent worktree add --new-branch=NAME blocked" \
  "git worktree add --new-branch=evil /tmp/d HEAD"

# Intermediate flag: `--track -b NAME`
echo "TC-057n: subagent + 'git worktree add --track -b newbr /tmp/d origin/main' → deny (intermediate -b)"
assert_subagent_deny "subagent worktree add --track -b blocked (intermediate flag)" \
  "git worktree add --track -b newbr /tmp/d origin/main"

# Positional postfix: `add /tmp/d -b newbr HEAD`
echo "TC-057o: subagent + 'git worktree add /tmp/d -b newbr HEAD' → deny (path-then-b postfix)"
assert_subagent_deny "subagent worktree add path-then-b blocked" \
  "git worktree add /tmp/d -b newbr HEAD"

# Absolute path bypass: `/usr/bin/git checkout -b ...`
echo "TC-057p: subagent + '/usr/bin/git checkout -b pr-994-test' → deny (absolute path bypass)"
assert_subagent_deny "subagent /usr/bin/git checkout -b blocked (absolute path bypass)" \
  "/usr/bin/git checkout -b pr-994-test"

# `command git` bypass
echo "TC-057q: subagent + 'command git checkout -b foo' → deny (command builtin bypass)"
assert_subagent_deny "subagent 'command git checkout -b' blocked" \
  "command git checkout -b foo"

# Backslash-escaped: `\git checkout`
echo "TC-057r: subagent + '\\\\git checkout -b foo' → deny (backslash-escaped bypass)"
assert_subagent_deny "subagent '\\\\git checkout -b' blocked (backslash-escape bypass)" \
  '\git checkout -b foo'

# --orphan flag for git worktree add (creates new orphan branch)
echo "TC-057s: subagent + 'git worktree add --orphan newbr /tmp/d' → deny (orphan branch creation)"
assert_subagent_deny "subagent worktree add --orphan blocked" \
  "git worktree add --orphan newbr /tmp/d"

# --------------------------------------------------------------------------
# TC-057t〜057z: cycle 3 — quote bypass + git global flag bypass
# (security-reviewer cycle 2 で empirical 発見した pre-existing limitation。
# Pattern 4 を quote 正規化 + global flag 正規化で structural に閉じる)
# --------------------------------------------------------------------------

# Quote bypass — Pattern 5 は既に `"` / `'` を正規化しているが Pattern 4 は非対称だった
echo "TC-057t: subagent + 'eval \"git checkout -b evil\"' → deny (eval quote bypass)"
assert_subagent_deny "subagent eval-quoted git checkout -b blocked" \
  'eval "git checkout -b evil"'

echo "TC-057u: subagent + 'sh -c \"git checkout -b evil\"' → deny (sh -c quote bypass)"
assert_subagent_deny "subagent sh -c quoted git checkout -b blocked" \
  'sh -c "git checkout -b evil"'

echo "TC-057v: subagent + 'bash -c \"git checkout -b evil\"' → deny (bash -c quote bypass)"
assert_subagent_deny "subagent bash -c quoted git checkout -b blocked" \
  'bash -c "git checkout -b evil"'

# git global flag bypass — `-C` / `--git-dir` / `--work-tree` 経由で verb を後置すると bypass
echo "TC-057w: subagent + 'git -C /tmp checkout -b evil' → deny (-C global flag bypass)"
assert_subagent_deny "subagent git -C <dir> checkout -b blocked" \
  "git -C /tmp checkout -b evil"

echo "TC-057x: subagent + 'git --git-dir=/tmp/.git checkout -b evil' → deny (--git-dir attached)"
assert_subagent_deny "subagent git --git-dir=X checkout -b blocked" \
  "git --git-dir=/tmp/.git checkout -b evil"

echo "TC-057y: subagent + 'git --work-tree /tmp checkout -b evil' → deny (--work-tree spaced)"
assert_subagent_deny "subagent git --work-tree X checkout -b blocked" \
  "git --work-tree /tmp checkout -b evil"

echo "TC-057z: subagent + 'git -C /tmp worktree add -b evil .wt HEAD' → deny (-C with worktree add)"
assert_subagent_deny "subagent git -C <dir> worktree add -b blocked" \
  "git -C /tmp worktree add -b evil .wt HEAD"

# Combined: quote + global flag double bypass
echo "TC-057aa: subagent + 'eval \"git -C /tmp checkout -b evil\"' → deny (combined bypass)"
assert_subagent_deny "subagent eval-quoted git -C checkout -b blocked (combined)" \
  'eval "git -C /tmp checkout -b evil"'

# Non-regression: bare flag `--bare` should still allow read-only verbs
echo "TC-057ab: subagent + 'git --bare log --oneline' → allow (--bare with read-only verb)"
assert_subagent_allow "subagent git --bare log allowed (--bare with read-only verb)" \
  "git --bare log --oneline"

# Non-regression: `git -C` with read-only verb should allow
echo "TC-057ac: subagent + 'git -C /tmp log --oneline' → allow (-C with read-only verb)"
assert_subagent_allow "subagent git -C log allowed (-C with read-only verb)" \
  "git -C /tmp log --oneline"

# --------------------------------------------------------------------------
# TC-057ad〜af: shell-wrapper の deny message に read-only probe 用の
# 代替ガイダンス (subshell / 直接実行 / bash <script>) を付加する。
# pattern 名 (reviewer-state-mutating-git) は既存テスト互換のため不変で、wrapper 専用の
# 理由・代替が reason に出ることを pin する。「(Z) bash -c 一律 block は緩和しない」判断のため、
# read-only git を包む wrapper も依然 deny されること、wrapper block が subagent 限定で
# main session は非影響であることも併せて固定する。
# --------------------------------------------------------------------------

# Helper: subagent deny かつ reason に wrapper guidance が含まれることを確認
assert_subagent_deny_wrapper_guidance() {
  local label="$1"
  local cmd="$2"
  local rc=0
  local output
  output=$(run_guard_with_transcript "Bash" "$cmd" "$SUBAGENT_TRANSCRIPT") || rc=$?
  local decision reason
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
  if [ "$decision" = "deny" ] \
    && [[ "$reason" == *"reviewer-state-mutating-git"* ]] \
    && [[ "$reason" == *"Shell-command wrappers"* ]] \
    && [[ "$reason" == *"subshell"* ]] \
    && [[ "$reason" == *"bash <script.sh>"* ]]; then
    pass "$label"
  else
    fail "$label — expected deny with shell-wrapper guidance, got decision=$decision reason=$reason"
  fi
}

echo "TC-057ad: subagent + 'bash -c \"echo readonly-probe\"' (no git) → deny + wrapper guidance"
assert_subagent_deny_wrapper_guidance "subagent non-git bash -c probe denied with wrapper guidance" \
  'bash -c "echo readonly-probe"'

echo "TC-057ae: subagent + 'bash -c \"git status\"' (read-only git wrapped) → deny + wrapper guidance (no relaxation)"
assert_subagent_deny_wrapper_guidance "subagent read-only-git bash -c probe still denied (policy: no relaxation)" \
  'bash -c "git status"'

echo "TC-057af: main session + 'bash -c \"echo readonly-probe\"' → allow (wrapper block is subagent-scoped)"
assert_main_allow "main session non-git bash -c allowed (wrapper block subagent-scoped)" \
  'bash -c "echo readonly-probe"'

# --------------------------------------------------------------------------
# TC-058: git fetch (bare) allowed, --prune denied
# --------------------------------------------------------------------------
echo "TC-058a: subagent + 'git fetch origin' (bare) → allow"
assert_subagent_allow "subagent bare git fetch allowed" "git fetch origin"

echo "TC-058b: subagent + 'git fetch --prune' → deny"
assert_subagent_deny "subagent git fetch --prune blocked" "git fetch --prune origin"

# --------------------------------------------------------------------------
# TC-059: Reviewer subagent + git reflog expire → deny
# --------------------------------------------------------------------------
echo "TC-059: subagent + 'git reflog expire --all' → deny"
assert_subagent_deny "subagent git reflog expire blocked" "git reflog expire --all --expire=now"

# --------------------------------------------------------------------------
# TC-060: Reviewer subagent + git tag -a (annotated tag creation) → deny
# --------------------------------------------------------------------------
echo "TC-060: subagent + 'git tag -a v1.0 -m msg' → deny"
assert_subagent_deny "subagent git tag -a blocked" "git tag -a v1.0 -m 'release'"

# --------------------------------------------------------------------------
# TC-061: False positive guard — quoted string containing 'git checkout'
# --------------------------------------------------------------------------
# The quote character `"` before `git` breaks the word boundary expected by
# the case-glob `*" git checkout "*`, so echoed strings containing the
# denylist verbs are correctly allowed. This TC locks in that behavior as a
# non-regression guarantee.
echo "TC-061: subagent + 'echo \"git checkout develop -- f\"' → allow (false positive guard)"
assert_subagent_allow "echoed 'git checkout' string allowed (quote boundary)" 'echo "git checkout develop -- f"'

# TC-061b: grep pattern argument containing 'git reset'
echo "TC-061b: subagent + 'grep \"git reset\" log.txt' → allow"
assert_subagent_allow "grep arg 'git reset' allowed (quote boundary)" 'grep "git reset" log.txt'

# --------------------------------------------------------------------------
# TC-062〜064: Main session non-regression for additional verbs
# --------------------------------------------------------------------------
echo "TC-062: main session + 'git add .' → allow"
assert_main_allow "main session git add allowed" "git add ."

echo "TC-063: main session + 'git commit -am msg' → allow"
assert_main_allow "main session git commit allowed" "git commit -am 'fix: msg'"

echo "TC-064: main session + 'git push origin' → allow"
assert_main_allow "main session git push allowed" "git push origin feat/foo"

# --------------------------------------------------------------------------
# Pattern 4 Cycle 3 additions
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# TC-065〜066: Newline (`\n`) bypass closure — cycle 2 HIGH regression
# cycle 2 で確認された「CMD_NORMALIZED に \n/\r が未正規化」経路を lock
# --------------------------------------------------------------------------
echo "TC-065: subagent + newline-separated 'true\\ngit reset' → deny"
assert_subagent_deny "newline boundary \\ngit reset blocked" $'true\ngit reset --hard HEAD'

echo "TC-066: subagent + 3-line script with 'git commit' → deny"
assert_subagent_deny "multi-line script git commit blocked" $'echo a\ngit commit -am wip\necho b'

echo "TC-066b: subagent + carriage-return '\\rgit checkout' → deny"
assert_subagent_deny "CR boundary \\rgit checkout blocked" $'true\rgit checkout develop'

# --------------------------------------------------------------------------
# TC-067〜074: Always-deny coverage expansion (cycle 2 MEDIUM - 46% → ~90%)
# 未カバー verb を array-driven loop で網羅
# --------------------------------------------------------------------------
echo "TC-067: subagent + always-deny verb coverage loop"
for verb_cmd in \
  "git pull origin main" \
  "git rm README.md" \
  "git clean -fd" \
  "git gc --aggressive" \
  "git prune --dry-run" \
  "git symbolic-ref HEAD refs/heads/foo" \
  "git am < /tmp/patch" \
  "git apply --index /tmp/patch" \
  "git mv old.md new.md" \
  "git notes add -m msg HEAD" \
  "git config user.email a@b.c" \
  "git remote add upstream https://github.com/foo/bar" \
  "git bisect start" \
  "git filter-branch --tree-filter 'rm -f foo' HEAD" \
  "git filter-repo --path foo --invert-paths" \
  "git replace old new"; do
  assert_subagent_deny "subagent '$verb_cmd' blocked" "$verb_cmd"
done

# --------------------------------------------------------------------------
# TC-068〜075: git stash sub-action coverage (8 mutating sub-actions)
# --------------------------------------------------------------------------
echo "TC-068: subagent + git stash sub-action coverage"
for stash_cmd in \
  "git stash pop" \
  "git stash drop stash@{0}" \
  "git stash apply stash@{1}" \
  "git stash clear" \
  "git stash save 'wip'" \
  "git stash create" \
  "git stash store abc123" \
  "git stash branch foo stash@{0}"; do
  assert_subagent_deny "subagent '$stash_cmd' blocked" "$stash_cmd"
done

# --------------------------------------------------------------------------
# TC-076〜080: git fetch regression guard — cycle 2 HIGH
# branch / remote 名に -p/-f を substring として含む bare fetch が
# allow されることを lock (cycle 1 で導入した Pattern 4(F) regression を閉塞)
# --------------------------------------------------------------------------
echo "TC-076: subagent + 'git fetch origin hot-fix' → allow (branch name contains -f)"
assert_subagent_allow "bare fetch hot-fix branch allowed" "git fetch origin hot-fix"

echo "TC-077: subagent + 'git fetch origin feature-patch' → allow (branch contains -p)"
assert_subagent_allow "bare fetch feature-patch branch allowed" "git fetch origin feature-patch"

echo "TC-078: subagent + 'git fetch origin release-focus' → allow"
assert_subagent_allow "bare fetch release-focus branch allowed" "git fetch origin release-focus"

echo "TC-079: subagent + 'git fetch origin v1.0-rc-final' → allow"
assert_subagent_allow "bare fetch v1.0-rc-final branch allowed" "git fetch origin v1.0-rc-final"

echo "TC-080: subagent + 'git fetch upstream main-pipeline' → allow"
assert_subagent_allow "bare fetch main-pipeline branch allowed" "git fetch upstream main-pipeline"

# --------------------------------------------------------------------------
# TC-081〜082: git fetch short-flag still denied (regression guard for fix)
# --------------------------------------------------------------------------
echo "TC-081: subagent + 'git fetch -p origin' → deny (short -p flag)"
assert_subagent_deny "short -p flag blocked" "git fetch -p origin"

echo "TC-082: subagent + 'git fetch -f origin' → deny (short -f flag)"
assert_subagent_deny "short -f flag blocked" "git fetch -f origin"

echo "TC-082b: subagent + 'git fetch --force upstream' → deny (long --force flag)"
assert_subagent_deny "long --force flag blocked" "git fetch --force upstream"

# --------------------------------------------------------------------------
# TC-083〜084: Brace/pipe/space-less bypass non-regression
# --------------------------------------------------------------------------
echo "TC-083: subagent + 'echo x|git reset' → deny (pipe boundary)"
assert_subagent_deny "pipe |git reset blocked" "echo x|git reset --hard HEAD"

echo "TC-084: subagent + '{git reset --hard HEAD;}' → deny (brace boundary)"
assert_subagent_deny "brace group git reset blocked" "{git reset --hard HEAD;}"

# alias of MAIN_TRANSCRIPT (above) — Tier 2/3 セクションを self-contained に保つため局所定義
MAIN_TRANSCRIPT_TC113="$MAIN_TRANSCRIPT"

# Helper: run hook with raw JSON input + clean env (Tier 3 env vars unset)
#   Optional 引数: $2 / $3 に `NAME=value` 形式を渡すと、env -u で unset した後に SET する
#   (TC-114 / TC-114b の Tier 3 env var 経路を helper 経由で表現可能にする)。
run_guard_clean_env() {
  local raw_input="$1"
  local set1="${2:-}"
  local set2="${3:-}"
  local rc=0
  local output
  # env(1) は引数順序で処理する: -u X で X を unset した直後の X=val は最終的に
  # X=val として export される。${var:+...} expansion により空引数を env に渡さない。
  output=$(env -u CLAUDE_SUBAGENT_TYPE -u CLAUDE_AGENT_TYPE ${set1:+"$set1"} ${set2:+"$set2"} bash -c 'echo "$1" | bash "$2" 2>"$3"' _ "$raw_input" "$HOOK" "$STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

# --------------------------------------------------------------------------
# TC-113: subagent_type field set → Tier 2 deny (git checkout blocked)
# --------------------------------------------------------------------------
echo "TC-113: input JSON subagent_type field → Tier 2 deny"
rc=0
tc113_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" '{tool_name: "Bash", tool_input: {command: "git checkout develop"}, cwd: "/tmp", transcript_path: $tp, subagent_type: "code-reviewer"}')
output=$(run_guard_clean_env "$tc113_input") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
stderr_log=$(cat "$STDERR_FILE")
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-state-mutating-git"* ]]; then
  pass "TC-113 subagent_type field triggers Tier 2 fallback"
else
  fail "TC-113 expected deny, got decision=$decision reason=$reason"
fi
if [[ "$stderr_log" == *"reviewer-state-mutating-git"* ]]; then
  pass "TC-113 stderr block log recorded"
else
  fail "TC-113 expected stderr block log, got: $stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# TC-113b: agent_type field set (subagent_type 不在) → Tier 2 deny
#   実装が `.subagent_type // .agent_type` の OR 経路を持つことを検証 (silent breakage 防止)
# --------------------------------------------------------------------------
echo "TC-113b: agent_type field set → Tier 2 deny"
rc=0
tc113b_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" '{tool_name: "Bash", tool_input: {command: "git checkout develop"}, cwd: "/tmp", transcript_path: $tp, agent_type: "code-reviewer"}')
output=$(run_guard_clean_env "$tc113b_input") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
stderr_log=$(cat "$STDERR_FILE")
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-state-mutating-git"* ]]; then
  pass "TC-113b agent_type field triggers Tier 2 fallback (OR with subagent_type)"
else
  fail "TC-113b expected deny, got decision=$decision reason=$reason"
fi
if [[ "$stderr_log" == *"reviewer-state-mutating-git"* ]]; then
  pass "TC-113b stderr block log recorded"
else
  fail "TC-113b expected stderr block log, got: $stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# TC-113c: subagent_type: "" (空文字列) → Tier 2 fires NOT (main session 扱い)
#   `| strings` filter + `[ -n "" ]` false により presence-only check が空文字を弾く挙動を検証
# --------------------------------------------------------------------------
echo "TC-113c: subagent_type=\"\" → Tier 2 does not fire (main session)"
rc=0
tc113c_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" '{tool_name: "Bash", tool_input: {command: "git checkout develop"}, cwd: "/tmp", transcript_path: $tp, subagent_type: ""}')
output=$(run_guard_clean_env "$tc113c_input") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-113c empty subagent_type does not trigger Tier 2 (main session preserved)"
else
  fail "TC-113c expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-113d: subagent_type=123 (non-string numeric) → Tier 2 fires NOT
#   `(.subagent_type | strings // "")` filter が numeric 値を空文字に正規化することを検証。
#   `| strings` filter を `// empty` 等に縮退する mutation を kill する coverage。
# --------------------------------------------------------------------------
echo "TC-113d: subagent_type=123 → Tier 2 does not fire (numeric rejected by | strings)"
rc=0
tc113d_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" '{tool_name: "Bash", tool_input: {command: "git checkout develop"}, cwd: "/tmp", transcript_path: $tp, subagent_type: 123}')
output=$(run_guard_clean_env "$tc113d_input") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-113d numeric subagent_type does not trigger Tier 2 (| strings filter rejects non-string)"
else
  fail "TC-113d expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-113e: subagent_type=[...] (non-string array) → Tier 2 fires NOT
#   `(.subagent_type | strings // "")` filter が array 値を空文字に正規化することを検証。
# --------------------------------------------------------------------------
echo "TC-113e: subagent_type=[...] → Tier 2 does not fire (array rejected by | strings)"
rc=0
tc113e_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" '{tool_name: "Bash", tool_input: {command: "git checkout develop"}, cwd: "/tmp", transcript_path: $tp, subagent_type: ["code-reviewer", "security"]}')
output=$(run_guard_clean_env "$tc113e_input") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-113e array subagent_type does not trigger Tier 2 (| strings filter rejects non-string)"
else
  fail "TC-113e expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-113f: subagent_type={...} (non-string object) → Tier 2 fires NOT
#   `(.subagent_type | strings // "")` filter が object 値を空文字に正規化することを検証。
# --------------------------------------------------------------------------
echo "TC-113f: subagent_type={...} → Tier 2 does not fire (object rejected by | strings)"
rc=0
tc113f_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" '{tool_name: "Bash", tool_input: {command: "git checkout develop"}, cwd: "/tmp", transcript_path: $tp, subagent_type: {name: "code-reviewer", level: 1}}')
output=$(run_guard_clean_env "$tc113f_input") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-113f object subagent_type does not trigger Tier 2 (| strings filter rejects non-string)"
else
  fail "TC-113f expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-114: CLAUDE_SUBAGENT_TYPE env var set → Tier 3 deny
#   run_guard_clean_env の第 2 引数で SUBAGENT 単独経路を検証 (helper 経由 = DRY)
# --------------------------------------------------------------------------
echo "TC-114: CLAUDE_SUBAGENT_TYPE env var → Tier 3 deny"
rc=0
tc114_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" '{tool_name: "Bash", tool_input: {command: "git reset --hard HEAD"}, cwd: "/tmp", transcript_path: $tp}')
output=$(run_guard_clean_env "$tc114_input" "CLAUDE_SUBAGENT_TYPE=code-reviewer") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
stderr_log=$(cat "$STDERR_FILE")
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-state-mutating-git"* ]]; then
  pass "TC-114 CLAUDE_SUBAGENT_TYPE triggers Tier 3 fallback"
else
  fail "TC-114 expected deny via env var, got decision=$decision reason=$reason"
fi
if [[ "$stderr_log" == *"reviewer-state-mutating-git"* ]]; then
  pass "TC-114 stderr block log recorded"
else
  fail "TC-114 expected stderr block log, got: $stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# TC-114b: CLAUDE_AGENT_TYPE env var single (SUBAGENT unset) → Tier 3 deny
#   実装 `[ -n "${CLAUDE_SUBAGENT_TYPE:-}" ] || [ -n "${CLAUDE_AGENT_TYPE:-}" ]` の OR 経路検証
# --------------------------------------------------------------------------
echo "TC-114b: CLAUDE_AGENT_TYPE env var → Tier 3 deny"
rc=0
tc114b_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" '{tool_name: "Bash", tool_input: {command: "git reset --hard HEAD"}, cwd: "/tmp", transcript_path: $tp}')
output=$(run_guard_clean_env "$tc114b_input" "CLAUDE_AGENT_TYPE=code-reviewer") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
stderr_log=$(cat "$STDERR_FILE")
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-state-mutating-git"* ]]; then
  pass "TC-114b CLAUDE_AGENT_TYPE triggers Tier 3 fallback (OR with CLAUDE_SUBAGENT_TYPE)"
else
  fail "TC-114b expected deny via env var, got decision=$decision reason=$reason"
fi
if [[ "$stderr_log" == *"reviewer-state-mutating-git"* ]]; then
  pass "TC-114b stderr block log recorded"
else
  fail "TC-114b expected stderr block log, got: $stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# TC-115: All three tiers unset → main session, git checkout allowed (regression guard)
# --------------------------------------------------------------------------
echo "TC-115: 3 tiers unset → main session allowed (regression guard)"
rc=0
tc115_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" '{tool_name: "Bash", tool_input: {command: "git checkout develop"}, cwd: "/tmp", transcript_path: $tp}')
output=$(run_guard_clean_env "$tc115_input") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-115 main session git checkout allowed (Tier 2/3 no false positives)"
else
  fail "TC-115 expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-116: deny fallback (jq -n emit failure) → valid JSON, deny preserved
#   stop-loop-continuation.test.sh TC-16 と同じ fake jq パターン: `jq -n` のみ exit 1 させ、
#   それ以外 (hook 冒頭の payload parse 等) は real jq へ委譲する。jq 全欠落は payload parse が
#   先に失敗して fail-open するため、現実的な fallback トリガーは emit-only の jq 失敗。
#   _deny_reason の構成要素は現状ハードコード文字列だが、fallback が改行 \n エスケープ +
#   neutralize_ctrl --c0-only を経由して valid JSON を emit し deny + exit 2 を維持することを pin する。
#   エスケープ連鎖そのものの非 vacuous 検証 (改行 / raw C0 実入力) は TC-117 が担う。
# --------------------------------------------------------------------------
echo "TC-116: deny fallback (jq -n emit failure) → valid JSON, deny preserved"
rc=0
real_jq=$(command -v jq)
tc116_input=$("$real_jq" -n '{tool_name: "Bash", tool_input: {command: "gh pr diff 123 --stat"}, cwd: "/tmp"}')
fake_bin_116=$(mktemp -d)
cat > "$fake_bin_116/jq" <<EOF
#!/bin/bash
if [ "\$1" = "-n" ]; then exit 1; fi
exec "$real_jq" "\$@"
EOF
chmod +x "$fake_bin_116/jq"
output=$(echo "$tc116_input" | PATH="$fake_bin_116:$PATH" bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
# Sanity pin: fallback 経路が emit した (primary jq 経路ではない)
if [ -n "$output" ]; then
  pass "TC-116 fallback emitted output despite jq -n failure"
else
  fail "TC-116 no output — fallback path not reached: $(cat -v "$STDERR_FILE")"
fi
if [ "$rc" = "2" ]; then
  pass "TC-116 fallback exits 2 (fail-closed deny contract)"
else
  fail "TC-116 expected rc=2, got rc=$rc"
fi
# RFC 8259 validity — 改行/C0 生バイトが文字列リテラルに残ると parse が失敗する
if printf '%s' "$output" | "$real_jq" -e . >/dev/null 2>&1; then
  pass "TC-116 fallback output is valid JSON"
else
  fail "TC-116 fallback output is not parseable JSON: $(printf '%s' "$output" | cat -v)"
fi
decision=$(printf '%s' "$output" | "$real_jq" -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(printf '%s' "$output" | "$real_jq" -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"gh-pr-diff-stat"* ]]; then
  pass "TC-116 deny decision and pattern name survive the fallback"
else
  fail "TC-116 expected deny with gh-pr-diff-stat via fallback, got decision=$decision reason=$reason"
fi
# raw C0 バイト (ESC 等) の非漏出 — neutralize_ctrl --c0-only の挙動 pin
if printf '%s' "$output" | LC_ALL=C grep -q $'\x1b'; then
  fail "TC-116 fallback JSON leaked a raw ESC byte: $(printf '%s' "$output" | cat -v)"
else
  pass "TC-116 fallback JSON contains no raw ESC byte"
fi
rm -rf "$fake_bin_116"
echo ""

# --------------------------------------------------------------------------
# TC-117: _bash_guard_escape_deny_reason — 改行/C0 実入力の非 vacuous 変換 pin
#   TC-116 は fallback 経路の構造契約 (到達 / rc=2 / deny 生存) を pin するが、現行の
#   _deny_reason は静的 ASCII のみで構成されるため、エスケープ連鎖そのものは no-op の
#   まま pass する (vacuous)。本 TC は hook から関数定義を境界行
#   (`_bash_guard_escape_deny_reason() {` 〜 `}`) で抽出し、改行 + raw ESC + CR + TAB +
#   backslash + double-quote を含む入力を直接流して変換を非 vacuous に検証する。
#   エスケープ連鎖のどの 1 行を欠落させても assertion が落ちる (mutation 耐性):
#   \\ 行欠落 → (3) invalid JSON (\s は invalid escape)、\" 行欠落 → (3) 構造破壊、
#   \n 行欠落 → (1) literal \n 不在 (改行は --c0-only で ? 化されるため)、
#   neutralize 行欠落 → (2) raw ESC 残存。
# --------------------------------------------------------------------------
echo "TC-117: _bash_guard_escape_deny_reason neutralizes newline/C0 input (non-vacuous)"
real_jq=$(command -v jq)
# 依存 helper (neutralize_ctrl) を source し、関数定義を hook から抽出して取り込む
source "$SCRIPT_DIR/../control-char-neutralize.sh"
eval "$(awk '/^_bash_guard_escape_deny_reason\(\) \{$/,/^\}$/' "$HOOK")"
if declare -f _bash_guard_escape_deny_reason >/dev/null 2>&1; then
  pass "TC-117 function extracted from hook"
  tc117_input=$(printf 'line1 "quoted" back\\slash\nline2 \x1b[31mred\x1b[0m tab:\there cr:\r.')
  tc117_out=$(_bash_guard_escape_deny_reason "$tc117_input") || tc117_out=""
  # (1) raw 改行ゼロ + literal \n 保存 (改行が neutralize で ? 化される mutation も検出)
  tc117_nl_count=$(printf '%s' "$tc117_out" | LC_ALL=C wc -l | tr -d ' ')
  if [ "$tc117_nl_count" = "0" ] && [[ "$tc117_out" == *'line1'*'\n'*'line2'* ]]; then
    pass "TC-117 newline escaped to literal \\n (no raw newline)"
  else
    fail "TC-117 newline not escaped (raw_nl=$tc117_nl_count): $(printf '%s' "$tc117_out" | cat -v)"
  fi
  # (2) raw ESC/TAB/CR バイトの非漏出 (? 化)
  tc117_c0_count=$(printf '%s' "$tc117_out" | LC_ALL=C tr -cd '\033\011\015' | LC_ALL=C wc -c | tr -d ' ')
  if [ "$tc117_c0_count" = "0" ]; then
    pass "TC-117 raw C0 bytes (ESC/TAB/CR) neutralized"
  else
    fail "TC-117 $tc117_c0_count raw C0 byte(s) leaked: $(printf '%s' "$tc117_out" | cat -v)"
  fi
  # (3) JSON 文字列リテラル埋め込みで valid JSON (RFC 8259)
  tc117_json=$(printf '{"reason":"%s"}' "$tc117_out")
  if printf '%s' "$tc117_json" | "$real_jq" -e . >/dev/null 2>&1; then
    pass "TC-117 escaped output embeds as valid JSON"
  else
    fail "TC-117 invalid JSON after embedding: $(printf '%s' "$tc117_json" | cat -v)"
  fi
  # (4) decode round-trip: " と \ の構造保持 + \n の実改行復元 + ESC の ? 化
  tc117_decoded=$(printf '%s' "$tc117_json" | "$real_jq" -r '.reason // empty' 2>/dev/null) || tc117_decoded=""
  if [[ "$tc117_decoded" == *'"quoted"'* ]] && [[ "$tc117_decoded" == *'back\slash'* ]] \
     && [[ "$tc117_decoded" == *$'\n'* ]] && [[ "$tc117_decoded" == *'?[31mred?[0m'* ]]; then
    pass "TC-117 quote/backslash/newline survive round-trip, ESC degraded to ?"
  else
    fail "TC-117 round-trip mismatch: $(printf '%s' "$tc117_decoded" | cat -v)"
  fi
else
  fail "TC-117 could not extract _bash_guard_escape_deny_reason from hook (boundary lines changed?)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-118: deny fallback neutralize 失敗 → static placeholder 縮退、deny + exit 2 維持
#   TC-116 は fallback 経路のエスケープ成功側 (reason に pattern 名が残る) を pin する。本 TC は
#   その先の二重障害 — fallback 内で _bash_guard_escape_deny_reason (neutralize_ctrl = 固定引数の
#   tr パイプ) まで失敗した場合 — の static placeholder 縮退を pin する。helper header が
#   「実質失敗しない」と明記する経路のため、fake tr で強制発火させる: neutralize_ctrl の
#   3 モードはいずれも第 1 引数に `\000-` レンジ文字列を持つので $1 マッチでのみ exit 1 し、
#   hook 内の他の tr 用途 (jq parse error path の `tr '\n' ' '` / flow-state contains_ctrl の
#   `tr -d ...` は $1=-d) は real tr へ委譲して巻き添えを防ぐ。
#   非 vacuous 性 (TC-116 の vacuous 教訓): neutralize 成功時は reason に pattern 名
#   (gh-pr-diff-stat) が入るため、「placeholder 文言あり + pattern 名なし」の両方向 assert で
#   縮退の発生そのものを証明する。
# --------------------------------------------------------------------------
echo "TC-118: deny fallback neutralize failure → static placeholder, deny + exit 2 preserved"
rc=0
real_jq=$(command -v jq)
real_tr=$(command -v tr)
tc118_input=$("$real_jq" -n '{tool_name: "Bash", tool_input: {command: "gh pr diff 123 --stat"}, cwd: "/tmp"}')
fake_bin_118=$(mktemp -d)
cat > "$fake_bin_118/jq" <<EOF
#!/bin/bash
if [ "\$1" = "-n" ]; then exit 1; fi
exec "$real_jq" "\$@"
EOF
cat > "$fake_bin_118/tr" <<EOF
#!/bin/bash
case "\$1" in *000-*) exit 1 ;; esac
exec "$real_tr" "\$@"
EOF
chmod +x "$fake_bin_118/jq" "$fake_bin_118/tr"
output=$(echo "$tc118_input" | PATH="$fake_bin_118:$PATH" bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
# Sanity pin: placeholder 縮退経路でも JSON を emit した (silent allow へ降格していない)
if [ -n "$output" ]; then
  pass "TC-118 placeholder path emitted output despite jq -n + tr failure"
else
  fail "TC-118 no output — placeholder path not reached: $(cat -v "$STDERR_FILE")"
fi
if [ "$rc" = "2" ]; then
  pass "TC-118 placeholder path exits 2 (fail-closed deny contract)"
else
  fail "TC-118 expected rc=2, got rc=$rc"
fi
if printf '%s' "$output" | "$real_jq" -e . >/dev/null 2>&1; then
  pass "TC-118 placeholder output is valid JSON"
else
  fail "TC-118 placeholder output is not parseable JSON: $(printf '%s' "$output" | cat -v)"
fi
decision=$(printf '%s' "$output" | "$real_jq" -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(printf '%s' "$output" | "$real_jq" -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ]; then
  pass "TC-118 deny decision survives the placeholder degradation"
else
  fail "TC-118 expected deny via placeholder path, got decision=$decision"
fi
# 縮退の発生証明 (非 vacuous): placeholder 文言あり + 通常 fallback の pattern 名なし
if [[ "$reason" == *"reason neutralization failed, fail-closed"* ]] && [[ "$reason" != *"gh-pr-diff-stat"* ]]; then
  pass "TC-118 reason degraded to the static placeholder (no pattern name leak)"
else
  fail "TC-118 expected static placeholder reason, got: $reason"
fi
# placeholder が案内する stderr ログの前提を pin (pattern 名はこちらに残る)
if grep -q "BLOCKED pattern=gh-pr-diff-stat" "$STDERR_FILE"; then
  pass "TC-118 stderr BLOCKED log keeps the pattern name (placeholder's referenced log)"
else
  fail "TC-118 stderr missing BLOCKED log: $(cat -v "$STDERR_FILE")"
fi
rm -rf "$fake_bin_118"
echo ""

# --------------------------------------------------------------------------
# TC-119〜124: Pattern 4 (security boundary) fail-closed vs Pattern 1-3 fail-open
#   Issue #1717: Pattern 4 (reviewer state-mutating-git denylist) shared the
#   fail-OPEN ERR trap with the convenience patterns, so a parse crash inside
#   Pattern 4 converged to exit 0 (allow) and silently bypassed the security
#   boundary. The fix installs a fail-CLOSED ERR trap over the Pattern 4 block
#   (deny + exit 2 + WARNING) and restores fail-open afterwards. Pattern 4 uses
#   only bash built-ins, so — unlike the deny-emit path faked in TC-118 — it
#   cannot be crashed via a fake external binary; the hook exposes a test-only,
#   fail-CLOSED-ONLY fault-injection env var (RITE_BTG_TEST_CRASH=pattern4) that
#   raises an ERR inside the fail-closed trap region (TC-119). A symmetric
#   fail-OPEN injection was deliberately NOT added — an env-triggered fail-open
#   path would be an allow-all backdoor to a security boundary — so AC-3 (Patterns
#   1-3 stay fail-open) is pinned structurally instead (TC-120). TC-123 covers the
#   timeout-bypass guard: an oversized global-flag command denies fail-closed before
#   the super-linear normalization can time out the fail-open hook. These TCs drive
#   the hook directly (the run_guard_* helpers do not thread extra env through the pipe).
# --------------------------------------------------------------------------
echo "TC-119: Pattern 4 crash in reviewer subagent → deny + exit 2 + stderr WARNING (AC-1)"
rc=0
tc119_input=$(jq -n --arg cmd "git status" --arg tp "$SUBAGENT_TRANSCRIPT" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}')
output=$(echo "$tc119_input" | RITE_BTG_TEST_CRASH=pattern4 bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
stderr_log=$(cat "$STDERR_FILE")
if [ "$rc" = "2" ]; then
  pass "TC-119 Pattern 4 crash exits 2 (fail-closed, not the old exit 0 allow)"
else
  fail "TC-119 expected rc=2, got rc=$rc"
fi
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-state-mutating-git"* ]]; then
  pass "TC-119 emits deny JSON with reviewer-state-mutating-git reason"
else
  fail "TC-119 expected deny (reviewer-state-mutating-git), got decision=$decision reason=$reason"
fi
if [[ "$stderr_log" == *"WARNING"* ]] && [[ "$stderr_log" == *"Pattern 4"* ]]; then
  pass "TC-119 stderr WARNING makes the fail-closed firing visible"
else
  fail "TC-119 expected stderr WARNING for Pattern 4, got: $stderr_log"
fi
echo ""

echo "TC-120: Patterns 1-3 fail-open invariant is structurally preserved (AC-3)"
# AC-3 requires that a crash in the Patterns 1-3 region still resolves to allow.
# This is guaranteed structurally: the default ERR trap is the fail-OPEN handler,
# and the fail-CLOSED trap is installed ONLY inside the reviewer-only Pattern 4
# block and restored to fail-open at that block's exit. We deliberately do NOT ship
# a fail-open fault-injection env var to drive this behaviorally — such a var would
# be an allow-all backdoor to the security boundary (Issue #1717 review F-02). So we
# pin the three invariants that guarantee AC-3 by inspecting the hook source.
tc120_src=$(cat "$HOOK")
# (a) the default (pre-Pattern-4) ERR trap is the fail-OPEN handler
if [[ "$tc120_src" == *"trap '_rite_btg_pattern13_fail_open' ERR"* ]]; then
  pass "TC-120 default ERR trap is the fail-open handler (Patterns 1-3 fail open)"
else
  fail "TC-120 default fail-open ERR trap not found in hook source"
fi
# (b) the fail-CLOSED trap is installed inside the Pattern 4 block (swap-in present)
if [[ "$tc120_src" == *"trap '_rite_btg_pattern4_fail_closed' ERR"* ]]; then
  pass "TC-120 fail-closed trap is swapped in for the Pattern 4 block"
else
  fail "TC-120 fail-closed swap line not found in hook source"
fi
# (c) the fail-OPEN trap is restored at Pattern 4 block exit. Pin the EXECUTABLE
# statement, not a comment: the fail-open trap line must appear at least TWICE — once
# as the default install (before Pattern 4) and once as the restore (block exit). This
# is now the only guard for AC-3's block-exit fail-open restoration (behavioral
# injection was removed as an allow-all backdoor, F-02), so it must catch deletion of
# the actual restore statement — not just its comment (Issue #1717 review F-04).
tc120_restore_count=$(printf '%s\n' "$tc120_src" | grep -c "trap '_rite_btg_pattern13_fail_open' ERR")
if [ "${tc120_restore_count:-0}" -ge 2 ]; then
  pass "TC-120 fail-open trap statement appears >=2x (default install + block-exit restore)"
else
  fail "TC-120 expected the fail-open trap statement >=2x (install+restore), found $tc120_restore_count"
fi
# (d) no fail-open fault-injection backdoor remains (F-02): the env var must never
# trigger an allow (fail-open) path. Assert the removed pattern13 injection is gone.
if [[ "$tc120_src" != *'RITE_BTG_TEST_CRASH:-}" = "pattern13"'* ]]; then
  pass "TC-120 no fail-open (pattern13) fault-injection backdoor remains"
else
  fail "TC-120 fail-open (pattern13) injection backdoor is still present in hook source"
fi
echo ""

echo "TC-121: Pattern 4 crash injection on a MAIN session → allow (no false deny; MUST NOT)"
# The fail-closed trap must be scoped to the reviewer-only Pattern 4 block. A main
# session never enters that block, so even with the injection var set it must not be
# denied — proves the fix does not add false denies to normal (non-reviewer) Bash.
rc=0
tc121_input=$(jq -n --arg cmd "git status" --arg tp "$MAIN_TRANSCRIPT" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}')
output=$(echo "$tc121_input" | RITE_BTG_TEST_CRASH=pattern4 bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-121 main-session Bash is not denied by the Pattern 4 fail-closed trap"
else
  fail "TC-121 expected allow (rc=0, empty) for main session, got rc=$rc output=$output"
fi
echo ""

echo "TC-122: hooks.json PreToolUse:Bash has a timeout (AC-4)"
HOOKS_JSON="$SCRIPT_DIR/../hooks.json"
if jq empty "$HOOKS_JSON" 2>/dev/null; then
  pass "TC-122 hooks.json is valid JSON"
else
  fail "TC-122 hooks.json is not valid JSON"
fi
tc122_timeout=$(jq -r '.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | test("pre-tool-bash-guard")) | .timeout // empty' "$HOOKS_JSON" 2>/dev/null)
if [ -n "$tc122_timeout" ] && [[ "$tc122_timeout" =~ ^[0-9]+$ ]]; then
  pass "TC-122 pre-tool-bash-guard hook has a numeric timeout ($tc122_timeout)"
else
  fail "TC-122 expected a numeric timeout on the PreToolUse:Bash hook, got '$tc122_timeout'"
fi
# Pin the exact value (Issue #1717 review F-03): the .sh header comment documents
# "a 10s timeout", but nothing tied that prose to the config. Pin 10 here so that
# changing hooks.json without updating the header comment fails this test (drift
# detection). Update BOTH this literal and the .sh header if the value ever changes.
if [ "$tc122_timeout" = "10" ]; then
  pass "TC-122 timeout value is 10 (matches the value documented in the .sh header)"
else
  fail "TC-122 expected timeout=10 (as documented in pre-tool-bash-guard.sh header), got '$tc122_timeout'"
fi
echo ""

echo "TC-123: many-global-flag command → iteration-cap fail-closed deny (F-01 secondary bound)"
# The Pattern 4 global-flag normalization is super-linear, and the PreToolUse hook
# timeout is fail-OPEN. A reviewer subagent could pad a git command with thousands of
# global flags so normalization times out → the deny is dropped → the git runs. The
# per-flag iteration cap denies fail-closed past 128 flags (a secondary bound; the
# length guard in TC-124 is the primary one). Use a READ-ONLY verb (`status`) under
# the byte ceiling so this exercises the CAP, not the length guard, and so the deny is
# genuinely attributable to the cap: without the cap the command would normalize to
# `git status` and be ALLOWED — with the cap it is denied (Issue #1717 review F-05).
rc=0
tc123_pad=$(printf -- '-C x %.0s' $(seq 1 400))
tc123_cmd="git ${tc123_pad}status"
tc123_input=$(jq -n --arg cmd "$tc123_cmd" --arg tp "$SUBAGENT_TRANSCRIPT" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}')
output=$(echo "$tc123_input" | bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ]; then
  pass "TC-123 many-global-flag READ-ONLY reviewer command is denied by the cap (allow→deny flip)"
else
  fail "TC-123 expected deny (cap fires on 400 flags), got decision=$decision rc=$rc"
fi
if [[ "$reason" == *"abnormally large"* ]]; then
  pass "TC-123 deny reason explains the oversized-command / timeout-bypass rationale"
else
  fail "TC-123 expected oversized-command explanation in reason, got: $reason"
fi
# Guard scope: the same command on a MAIN session must NOT be denied (main sessions
# never enter Pattern 4 — the cap must not add false denies to non-reviewer Bash).
rc=0
tc123_main_input=$(jq -n --arg cmd "$tc123_cmd" --arg tp "$MAIN_TRANSCRIPT" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}')
output=$(echo "$tc123_main_input" | bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-123 many-global-flag MAIN-session command is not denied by the reviewer-only cap"
else
  fail "TC-123 expected allow (rc=0, empty) for oversized main-session command, got rc=$rc output=$output"
fi
echo ""

echo "TC-124: oversized command → length-guard fail-closed deny WITHOUT the O(n²) paths (F-01b)"
# The PRIMARY F-01 bound (Issue #1717 review F-01b showed the iteration cap alone was
# insufficient): any reviewer command over the byte ceiling is denied fail-closed
# BEFORE the O(n²) heredoc strip (${COMMAND%%<<*}, ~45s on ~1.3MB) and the O(n²) Pattern
# 2 regex (>2min on a few MB) — both of which would otherwise time out the fail-open
# hook and let the padded git run. Build huge commands via temp file + --rawfile to
# avoid argv limits, and pin that the deny is FAST (proves the O(n²) work is skipped).
tc124_dir=$(mktemp -d)
tc124_bigval=$(printf 'x%.0s' $(seq 1 10000))
# (a) 1.28MB state-mutating (checkout) padded with huge flag values → fast deny
{ printf 'git '; for _i in $(seq 1 128); do printf -- '-C %s ' "$tc124_bigval"; done; printf 'checkout evil'; } > "$tc124_dir/cmd.txt"
jq -n --rawfile cmd "$tc124_dir/cmd.txt" --arg tp "$SUBAGENT_TRANSCRIPT" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}' > "$tc124_dir/in.json"
rc=0
_t0=$(date +%s%N)
output=$(timeout 15 bash "$HOOK" < "$tc124_dir/in.json" 2>"$STDERR_FILE") || rc=$?
_t1=$(date +%s%N)
_ms=$(( (_t1 - _t0) / 1000000 ))
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [ "$rc" != "124" ]; then
  pass "TC-124 oversized (1.3MB) reviewer command is denied fail-closed"
else
  fail "TC-124 expected deny for oversized command, got decision=$decision rc=$rc"
fi
if [ "$_ms" -lt 5000 ]; then
  pass "TC-124 oversized deny completes fast (${_ms}ms < 5s — O(n²) paths skipped, no timeout→fail-open)"
else
  fail "TC-124 oversized deny too slow (${_ms}ms) — length guard is not short-circuiting the O(n²) work"
fi
# (b) oversized (~80KB) READ-ONLY command → deny (allow→deny flip; a small `git status` allows)
{ printf 'git '; for _i in $(seq 1 8); do printf -- '-C %s ' "$tc124_bigval"; done; printf 'status'; } > "$tc124_dir/ro.txt"
jq -n --rawfile cmd "$tc124_dir/ro.txt" --arg tp "$SUBAGENT_TRANSCRIPT" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}' > "$tc124_dir/roin.json"
rc=0
output=$(timeout 15 bash "$HOOK" < "$tc124_dir/roin.json" 2>"$STDERR_FILE") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [ "$decision" = "deny" ]; then
  pass "TC-124 oversized READ-ONLY reviewer command is denied (length guard, allow→deny flip)"
else
  fail "TC-124 expected deny for oversized read-only command, got decision=$decision rc=$rc"
fi
# (c) oversized because of a huge heredoc BODY, with a READ-ONLY prefix → deny.
# The length guard checks ${#COMMAND} over the WHOLE command (heredoc body included),
# so it fires here. Non-vacuous (Issue #1717 review F-06): the prefix `git status` is
# read-only, so WITHOUT the length guard the heredoc strip yields `git status` and the
# command is ALLOWED — WITH it the command is denied. (Note: the `<<` sits near the
# front, so `${COMMAND%%<<*}` is itself fast here regardless — this case pins the
# length guard's use of the full command length, not the O(n²) strip skip; the O(n²)
# no-heredoc path is covered by (a).)
{ printf 'git status <<EOF\n'; printf 'y%.0s' $(seq 1 200000); printf '\nEOF'; } > "$tc124_dir/hd.txt"
jq -n --rawfile cmd "$tc124_dir/hd.txt" --arg tp "$SUBAGENT_TRANSCRIPT" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}' > "$tc124_dir/hdin.json"
rc=0
output=$(timeout 15 bash "$HOOK" < "$tc124_dir/hdin.json" 2>"$STDERR_FILE") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [ "$decision" = "deny" ]; then
  pass "TC-124 heredoc-body-oversized READ-ONLY command is denied (length guard uses full command length)"
else
  fail "TC-124 expected deny for heredoc-body-oversized read-only command, got decision=$decision rc=$rc"
fi
# (d) oversized (~80KB) MAIN-session command → must NOT be denied (MUST NOT — reviewer-only guard)
jq -n --rawfile cmd "$tc124_dir/ro.txt" --arg tp "$MAIN_TRANSCRIPT" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}' > "$tc124_dir/mainin.json"
rc=0
output=$(timeout 15 bash "$HOOK" < "$tc124_dir/mainin.json" 2>"$STDERR_FILE") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [ "$decision" != "deny" ]; then
  pass "TC-124 oversized MAIN-session command is not denied by the reviewer-only length guard"
else
  fail "TC-124 oversized main-session command was wrongly denied (MUST NOT violation)"
fi
rm -rf "$tc124_dir"
echo ""

# --------------------------------------------------------------------------
# TC-125: reviewer WRITE into a .git directory (Issue #1864 AC-1, sub-block (H))
# The Bash-tool sibling of pre-tool-edit-guard's .git protection: a reviewer must not
# `echo pwned > .git/hooks/pre-commit` (RCE via next git op). Reading .git stays allowed.
# --------------------------------------------------------------------------
# --- Helper: deny assertion for the reviewer-gitdir-write pattern ---
assert_subagent_deny_gitdir() {
  local label="$1"
  local cmd="$2"
  local rc=0
  local output
  output=$(run_guard_with_transcript "Bash" "$cmd" "$SUBAGENT_TRANSCRIPT") || rc=$?
  local decision reason
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
  if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-gitdir-write"* ]]; then
    pass "$label"
  else
    fail "$label — expected deny (reviewer-gitdir-write), got decision=$decision reason=$reason"
  fi
}

echo "TC-125a: subagent redirect into .git/hooks → deny"
assert_subagent_deny_gitdir "echo > .git/hooks/pre-commit blocked" "echo pwned > .git/hooks/pre-commit"

echo "TC-125b: subagent append (>>) into .git/hooks → deny"
assert_subagent_deny_gitdir "echo >> .git/hooks/pre-commit blocked" "echo pwned >> .git/hooks/pre-commit"

echo "TC-125c: subagent redirect (no space) into .git/config → deny"
assert_subagent_deny_gitdir "echo >.git/config blocked" "echo x >.git/config"

echo "TC-125d: subagent redirect into ABSOLUTE .git path → deny"
assert_subagent_deny_gitdir "abs .git redirect blocked" "echo x > /tmp/repo/.git/hooks/pre-commit"

echo "TC-125e: subagent redirect into ./.git → deny (leading ./)"
assert_subagent_deny_gitdir "./.git redirect blocked" "echo x > ./.git/config"

echo "TC-125f: subagent redirect with QUOTED .git target → deny"
assert_subagent_deny_gitdir "quoted .git target blocked" "echo x > \".git/hooks/pre-commit\""

echo "TC-125g: subagent redirect into .git after a meta-boundary (&&) → deny"
assert_subagent_deny_gitdir "compound redirect into .git blocked" "cat foo && echo x > .git/config"

echo "TC-125h: subagent tee into .git/hooks → deny"
assert_subagent_deny_gitdir "tee into .git blocked" "echo x | tee .git/hooks/pre-commit"

echo "TC-125i: subagent cp into .git/hooks → deny"
assert_subagent_deny_gitdir "cp into .git blocked" "cp /tmp/evil .git/hooks/pre-commit"

echo "TC-125j: subagent ln -s into .git/hooks → deny"
assert_subagent_deny_gitdir "ln -s into .git blocked" "ln -s /tmp/evil .git/hooks/pre-commit"

echo "TC-125k: subagent mv into .git → deny"
assert_subagent_deny_gitdir "mv into .git blocked" "mv /tmp/evil .git/hooks/pre-commit"

# --- ALLOW cases: the AC's own false-positive gate ("read-only git / tests not mis-detected") ---
echo "TC-125-ALLOW-a: subagent READS .git/config (cat) → allow"
assert_subagent_allow "cat .git/config allowed (read, not write)" "cat .git/config"

echo "TC-125-ALLOW-b: subagent LISTS .git/hooks (ls) → allow"
assert_subagent_allow "ls .git/hooks/ allowed" "ls .git/hooks/"

echo "TC-125-ALLOW-c: subagent greps .git/config → allow"
assert_subagent_allow "grep .git/config allowed" "grep hooksPath .git/config"

echo "TC-125-ALLOW-d: subagent legit isolation worktree setup → allow"
assert_subagent_allow "git worktree add --detach (isolation) allowed" \
  "git worktree add --detach /tmp/rite-review-mutation-abc HEAD"

echo "TC-125-ALLOW-e: boundary — dir literally named 'foo.git/' is NOT the .git component → allow"
assert_subagent_allow "redirect into myrepo.git/description NOT blocked" "echo x > myrepo.git/description"

echo "TC-125-ALLOW-f: redirect into a NON-.git path → allow"
assert_subagent_allow "redirect into /tmp/out.txt allowed" "echo x > /tmp/out.txt"

echo "TC-125-ALLOW-g: .git as INPUT-redirect source (read) → allow"
assert_subagent_allow "tee reading FROM .git via < allowed" "tee /tmp/x < .git/config"

echo "TC-125-ALLOW-h: MAIN session redirect into .git → allow (reviewer-only guard)"
assert_main_allow "main-session .git write not blocked by (H)" "echo x > .git/hooks/pre-commit"
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
