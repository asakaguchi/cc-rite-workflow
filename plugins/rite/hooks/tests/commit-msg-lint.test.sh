#!/bin/bash
# Tests for charter-lint commit-msg detection in pre-tool-bash-guard.sh
# Test fixtures intentionally contain charter-forbidden patterns as
# regex/metavariable input — these are excluded from charter §禁止パターン
# scope (test inputs, not document statements).
# Usage: bash plugins/rite/hooks/tests/commit-msg-lint.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../pre-tool-bash-guard.sh"
PASS=0
FAIL=0
STDERR_FILE=$(mktemp)
TEST_REPO=""

cleanup() {
  rm -f "$STDERR_FILE"
  if [ -n "$TEST_REPO" ] && [ -d "$TEST_REPO" ]; then
    rm -rf "$TEST_REPO"
  fi
}
trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

# Setup a fresh temporary git repo with one staged file. Cleans previous one.
setup_git_repo() {
  local staged_path="${1:-src/foo.txt}"
  if [ -n "$TEST_REPO" ] && [ -d "$TEST_REPO" ]; then
    rm -rf "$TEST_REPO"
  fi
  TEST_REPO=$(mktemp -d)
  (
    cd "$TEST_REPO"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    mkdir -p "$(dirname "$staged_path")"
    echo "content" > "$staged_path"
    git add "$staged_path"
  )
}

# Run the hook with the given command. Optional second arg "true" enables
# RITE_COMMIT_LINT_STRICT. Hook is invoked from within $TEST_REPO so
# `git diff --cached` reflects the staged file.
run_guard() {
  local cmd="$1"
  local strict="${2:-}"
  local rc=0
  local output
  if [ "$strict" = "true" ]; then
    output=$(cd "$TEST_REPO" && jq -n --arg cmd "$cmd" --arg cwd "$TEST_REPO" \
      '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}' \
      | RITE_COMMIT_LINT_STRICT=true bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
  else
    output=$(cd "$TEST_REPO" && jq -n --arg cmd "$cmd" --arg cwd "$TEST_REPO" \
      '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}' \
      | bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
  fi
  echo "$output"
  return $rc
}

# Safe extraction of permissionDecision: empty string when stdout is not JSON.
get_decision() {
  local output="$1"
  if [ -z "$output" ]; then
    echo ""
    return
  fi
  if echo "$output" | jq empty 2>/dev/null; then
    echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null
  else
    echo ""
  fi
}

echo "=== commit-msg-lint.test.sh ==="
echo ""

# --------------------------------------------------------------------------
# T-01: charter pattern in -m + STRICT unset → WARN (exit 0, stderr only)
# --------------------------------------------------------------------------
echo "T-01: charter pattern + RITE_COMMIT_LINT_STRICT unset → WARN (exit 0)"
setup_git_repo
rc=0
output=$(run_guard "git commit -m \"fix: handle cycle 3 retry path\"") || rc=$?
stderr_log=$(cat "$STDERR_FILE")
decision=$(get_decision "$output")
if [ "$rc" = "0" ] \
   && [ "$decision" != "deny" ] \
   && [[ "$stderr_log" == *"[charter-lint] WARN:"* ]] \
   && [[ "$stderr_log" != *"[charter-lint] BLOCK:"* ]]; then
  pass "WARN emitted, exit 0, no JSON deny"
else
  fail "Expected exit 0 + WARN, got rc=$rc decision=$decision stderr=$stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# T-02: charter pattern + STRICT=true → BLOCK (exit non-zero, JSON deny)
# --------------------------------------------------------------------------
echo "T-02: charter pattern + RITE_COMMIT_LINT_STRICT=true → BLOCK (exit non-zero)"
setup_git_repo
rc=0
output=$(run_guard "git commit -m \"refactor: cycle 5 cleanup\"" "true") || rc=$?
stderr_log=$(cat "$STDERR_FILE")
decision=$(get_decision "$output")
if [ "$rc" -ne 0 ] \
   && [ "$decision" = "deny" ] \
   && [[ "$stderr_log" == *"[charter-lint] BLOCK:"* ]]; then
  pass "BLOCK emitted, exit non-zero, JSON deny"
else
  fail "Expected exit !=0 + BLOCK + deny, got rc=$rc decision=$decision stderr=$stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# T-03: docs/designs/* only commit + STRICT + pattern → exclusion (no warn/block)
# --------------------------------------------------------------------------
echo "T-03: docs/designs/* only + STRICT + pattern → exclusion"
setup_git_repo "docs/designs/example.md"
rc=0
output=$(run_guard "git commit -m \"docs: cycle 1 example for design notes\"" "true") || rc=$?
stderr_log=$(cat "$STDERR_FILE")
decision=$(get_decision "$output")
if [ "$rc" = "0" ] \
   && [ "$decision" != "deny" ] \
   && [[ "$stderr_log" != *"[charter-lint]"* ]]; then
  pass "docs/designs/ exclusion: no charter-lint output"
else
  fail "Expected exclusion, got rc=$rc decision=$decision stderr=$stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# T-04: pattern only inside fenced code block + STRICT → exclusion
# --------------------------------------------------------------------------
echo "T-04: code block exclusion + STRICT + pattern inside fence → exclusion"
setup_git_repo
fenced_msg=$'docs: refactor\n\n```\nverified-review cycle 3\n```\n\nNo violations outside the fence.'
rc=0
output=$(run_guard "git commit -m \"$fenced_msg\"" "true") || rc=$?
stderr_log=$(cat "$STDERR_FILE")
decision=$(get_decision "$output")
if [ "$rc" = "0" ] \
   && [ "$decision" != "deny" ] \
   && [[ "$stderr_log" != *"[charter-lint]"* ]]; then
  pass "code block exclusion: no charter-lint output"
else
  fail "Expected exclusion, got rc=$rc decision=$decision stderr=$stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# T-05: normal Conventional Commits message → pass through (non-regression)
# --------------------------------------------------------------------------
echo "T-05: normal commit message (no charter pattern) → pass through"
setup_git_repo
rc=0
output=$(run_guard "git commit -m \"feat(rite): add new feature\"") || rc=$?
stderr_log=$(cat "$STDERR_FILE")
if [ "$rc" = "0" ] && [[ "$stderr_log" != *"[charter-lint]"* ]]; then
  pass "no charter-lint output for normal Conventional Commits message"
else
  fail "Expected clean pass, got rc=$rc stderr=$stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# T-06: -F file with pattern + STRICT → BLOCK
# --------------------------------------------------------------------------
echo "T-06: -F file with charter pattern + STRICT → BLOCK"
setup_git_repo
msg_file=$(mktemp)
printf 'fix: cycle 7 trailing newlines\n' > "$msg_file"
rc=0
output=$(run_guard "git commit -F $msg_file" "true") || rc=$?
stderr_log=$(cat "$STDERR_FILE")
decision=$(get_decision "$output")
rm -f "$msg_file"
if [ "$rc" -ne 0 ] \
   && [ "$decision" = "deny" ] \
   && [[ "$stderr_log" == *"[charter-lint] BLOCK:"* ]]; then
  pass "-F file BLOCK in STRICT mode"
else
  fail "Expected exit !=0 + BLOCK, got rc=$rc decision=$decision stderr=$stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
