#!/bin/bash
# Tests for pre-tool-edit-guard.sh (PreToolUse hook, Issue #1860)
# Usage: bash plugins/rite/hooks/tests/pre-tool-edit-guard.test.sh
#
# Verifies AC-1 (reviewer subagent Edit/Write/MultiEdit/NotebookEdit to the parent
# working tree is denied) and AC-4 (normal review and isolated-worktree mutation
# testing are NOT false-denied).
set -euo pipefail

# Tier 3 (env var) subagent detection: a host env with these set would make the
# main-session allow tests deny via Tier 3 and flake. Neutralize like the sibling
# pre-tool-bash-guard.test.sh does.
unset CLAUDE_SUBAGENT_TYPE CLAUDE_AGENT_TYPE

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../pre-tool-edit-guard.sh"
PASS=0
FAIL=0
STDERR_FILE=$(mktemp)

# A real git repo so `git -C "$cwd" rev-parse --show-toplevel` resolves (the
# repo-internal check). A sanctioned reviewer isolation dir sits OUTSIDE it.
TEST_REPO=$(mktemp -d)
ISO_MUT_DIR=$(mktemp -d -t rite-review-mutation-XXXXXX)
ISO_REV_DIR=$(mktemp -d -t rite-revert-test-XXXXXX)
OUTSIDE_DIR=$(mktemp -d)
( cd "$TEST_REPO" && git init -q && git config user.email t@t && git config user.name t )

cleanup() {
  rm -f "$STDERR_FILE"
  rm -rf "$TEST_REPO" "$ISO_MUT_DIR" "$ISO_REV_DIR" "$OUTSIDE_DIR"
}
trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

SUBAGENT_TRANSCRIPT="/home/user/.claude/projects/proj/session-id/subagents/agent-abc123.jsonl"
MAIN_TRANSCRIPT="/home/user/.claude/projects/proj/session-id/main.jsonl"

# Build a PreToolUse envelope and pipe it to the hook.
#   $1 tool_name  $2 file/notebook path  $3 cwd  $4 transcript_path
# NotebookEdit populates tool_input.notebook_path; the rest use file_path.
run_edit_guard() {
  local tool_name="$1" path="$2" cwd="$3" transcript="$4"
  local field="file_path"
  [ "$tool_name" = "NotebookEdit" ] && field="notebook_path"
  local rc=0 output
  output=$(jq -n --arg tn "$tool_name" --arg p "$path" --arg cwd "$cwd" \
    --arg tp "$transcript" --arg field "$field" \
    '{tool_name: $tn, tool_input: {($field): $p}, cwd: $cwd, transcript_path: $tp}' \
    | bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

decision_of() { echo "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
reason_of()   { echo "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }

echo "=== pre-tool-edit-guard.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# (a) subagent Edit to a parent-working-tree file → deny
# --------------------------------------------------------------------------
echo "TC-A: subagent Edit to parent working tree → deny"
out=$(run_edit_guard "Edit" "$TEST_REPO/src/bets.py" "$TEST_REPO" "$SUBAGENT_TRANSCRIPT") || true
if [ "$(decision_of "$out")" = "deny" ] && [[ "$(reason_of "$out")" == *"reviewer-edit-parent-tree"* ]]; then
  pass "subagent Edit to repo file blocked"
else
  fail "Expected deny, got decision=$(decision_of "$out") reason=$(reason_of "$out")"
fi
if grep -q "edit-guard: BLOCKED" "$STDERR_FILE"; then
  pass "stderr contains block log"
else
  fail "Expected stderr block log, got: $(cat "$STDERR_FILE")"
fi
echo ""

# --------------------------------------------------------------------------
# (a2) subagent Edit with RELATIVE path (cwd=repo) → deny (relative join)
# --------------------------------------------------------------------------
echo "TC-A2: subagent Edit relative path under repo → deny"
out=$(run_edit_guard "Edit" "src/bets.py" "$TEST_REPO" "$SUBAGENT_TRANSCRIPT") || true
if [ "$(decision_of "$out")" = "deny" ]; then
  pass "subagent Edit (relative) to repo file blocked"
else
  fail "Expected deny, got decision=$(decision_of "$out")"
fi
echo ""

# --------------------------------------------------------------------------
# (b) subagent Edit under rite-review-mutation-* (reviewer cd'd in) → allow
# --------------------------------------------------------------------------
echo "TC-B: subagent Edit under rite-review-mutation-* isolation dir → allow"
out=$(run_edit_guard "Edit" "some-file.sh" "$ISO_MUT_DIR" "$SUBAGENT_TRANSCRIPT") && rc=0 || rc=$?
if [ "$rc" = "0" ] && [ -z "$out" ]; then
  pass "isolated mutation-worktree edit allowed (AC-4)"
else
  fail "Expected allow (exit 0, no output), got rc=$rc out=$out"
fi
echo ""

# --------------------------------------------------------------------------
# (e) subagent Edit under rite-revert-test-* → allow
# --------------------------------------------------------------------------
echo "TC-E: subagent Edit under rite-revert-test-* isolation dir → allow"
out=$(run_edit_guard "Write" "$ISO_REV_DIR/probe.txt" "$ISO_REV_DIR" "$SUBAGENT_TRANSCRIPT") && rc=0 || rc=$?
if [ "$rc" = "0" ] && [ -z "$out" ]; then
  pass "isolated revert-test-worktree edit allowed (AC-4)"
else
  fail "Expected allow, got rc=$rc out=$out"
fi
echo ""

# --------------------------------------------------------------------------
# (c) main-session Edit to parent tree → allow (primary AC-4 guarantee)
# --------------------------------------------------------------------------
echo "TC-C: main-session Edit to parent working tree → allow"
out=$(run_edit_guard "Edit" "$TEST_REPO/src/bets.py" "$TEST_REPO" "$MAIN_TRANSCRIPT") && rc=0 || rc=$?
if [ "$rc" = "0" ] && [ -z "$out" ]; then
  pass "main-session edit not blocked (implement.md Edit/Write unaffected)"
else
  fail "Expected allow, got rc=$rc out=$out"
fi
echo ""

# --------------------------------------------------------------------------
# (d) tool parity: subagent Write / MultiEdit / NotebookEdit to parent tree → deny
# --------------------------------------------------------------------------
for tool in Write MultiEdit NotebookEdit; do
  echo "TC-D-$tool: subagent $tool to parent working tree → deny"
  path="$TEST_REPO/src/mod.py"
  [ "$tool" = "NotebookEdit" ] && path="$TEST_REPO/nb.ipynb"
  out=$(run_edit_guard "$tool" "$path" "$TEST_REPO" "$SUBAGENT_TRANSCRIPT") || true
  if [ "$(decision_of "$out")" = "deny" ]; then
    pass "$tool to repo file blocked"
  else
    fail "Expected deny for $tool, got decision=$(decision_of "$out")"
  fi
  echo ""
done

# --------------------------------------------------------------------------
# (f) subagent Edit outside repo AND outside isolation → allow (not repo-internal)
# --------------------------------------------------------------------------
echo "TC-F: subagent Edit to /tmp scratch outside repo → allow"
out=$(run_edit_guard "Edit" "$OUTSIDE_DIR/scratch.txt" "$OUTSIDE_DIR" "$SUBAGENT_TRANSCRIPT") && rc=0 || rc=$?
if [ "$rc" = "0" ] && [ -z "$out" ]; then
  pass "non-repo scratch edit allowed"
else
  fail "Expected allow, got rc=$rc out=$out"
fi
echo ""

# --------------------------------------------------------------------------
# (g) non-matching tool (Bash) → allow (defense-in-depth against matcher drift)
# --------------------------------------------------------------------------
echo "TC-G: non-Edit tool (Bash) → allow (exit 0, no output)"
out=$(jq -n --arg tp "$SUBAGENT_TRANSCRIPT" \
  '{tool_name: "Bash", tool_input: {command: "git status"}, cwd: "/tmp", transcript_path: $tp}' \
  | bash "$HOOK" 2>"$STDERR_FILE") && rc=0 || rc=$?
if [ "$rc" = "0" ] && [ -z "$out" ]; then
  pass "Bash tool ignored by edit-guard"
else
  fail "Expected allow, got rc=$rc out=$out"
fi
echo ""

# --------------------------------------------------------------------------
# (h) Tier 3 env-var subagent detection: main transcript but env set → deny
# --------------------------------------------------------------------------
echo "TC-H: env-var (Tier 3) subagent detection to parent tree → deny"
out=$(CLAUDE_SUBAGENT_TYPE="code-quality-reviewer" jq -n --arg p "$TEST_REPO/src/x.py" --arg cwd "$TEST_REPO" --arg tp "$MAIN_TRANSCRIPT" \
  '{tool_name: "Edit", tool_input: {file_path: $p}, cwd: $cwd, transcript_path: $tp}' \
  | CLAUDE_SUBAGENT_TYPE="code-quality-reviewer" bash "$HOOK" 2>"$STDERR_FILE") || true
if [ "$(decision_of "$out")" = "deny" ]; then
  pass "Tier 3 env-var subagent detection blocks parent-tree edit"
else
  fail "Expected deny, got decision=$(decision_of "$out")"
fi
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
