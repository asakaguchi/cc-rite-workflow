#!/bin/bash
# Tests for wiki-ingest-commit.sh
# Usage: bash plugins/rite/hooks/tests/wiki-ingest-commit.test.sh
#
# Coverage scope: same_branch path's `_sb_dump` stderr helper only. The
# separate_branch path's `dump_git_err` invocations are intentionally out of
# scope for these static pins because exercising them requires a real
# wiki-branch git fixture (worktree, checkout, stash) whose CI setup cost
# exceeds the regression risk for that path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SRC="$SCRIPT_DIR/../scripts/wiki-ingest-commit.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

echo "=== wiki-ingest-commit.sh static-pin tests ==="
echo ""

if [ ! -f "$HOOK_SRC" ]; then
  echo "ERROR: $HOOK_SRC not found" >&2
  exit 1
fi

# --- TC-SB-DUMP: same_branch strategy ships a _sb_dump stderr helper ---
# The shared dump_git_err helper is declared further down in the file under
# the separate_branch block, so the same_branch path needs its own local
# helper to surface git stderr. Without it, git add / commit failures
# collapse into an opaque "ERROR" line with no root cause.
echo "TC-SB-DUMP: same_branch defines and uses _sb_dump helper"
if grep -qE '^[[:space:]]*_sb_dump\(\)' "$HOOK_SRC"; then
  pass "_sb_dump function is defined"
else
  fail "_sb_dump function missing — same_branch git failures lose stderr context"
fi
echo ""

# --- TC-SB-CALL: _sb_dump is invoked on both git add and git commit failure ---
echo "TC-SB-CALL: _sb_dump is called from both git failure branches"
add_calls=$(grep -cE '_sb_dump "add"' "$HOOK_SRC" || true)
commit_calls=$(grep -cE '_sb_dump "commit"' "$HOOK_SRC" || true)
if [ "$add_calls" -ge 1 ] && [ "$commit_calls" -ge 1 ]; then
  pass "_sb_dump invoked from both git add and git commit failure paths"
else
  fail "_sb_dump call missing (add=$add_calls, commit=$commit_calls) — silent failure regression possible"
fi
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
