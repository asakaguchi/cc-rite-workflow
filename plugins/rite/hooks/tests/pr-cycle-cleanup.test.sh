#!/bin/bash
# Tests for pr-cycle-cleanup.sh
# Usage: bash plugins/rite/hooks/tests/pr-cycle-cleanup.test.sh
#
# Test cases map to Issue #919 Acceptance Criteria:
#   T-01 → AC-1: 1 サイクル正常終了後の残置ゼロ
#   T-02 → AC-2: 複数サイクル後の残置ゼロ
#   T-03 → AC-3: 異常終了時の回復経路
#   T-04 → AC-4: 無関係ブランチの保護
#
# Each test creates an isolated temp git repository, simulates branch /
# worktree creation, runs the cleanup script, and asserts the result.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLEANUP="$SCRIPT_DIR/../scripts/pr-cycle-cleanup.sh"
PASS=0
FAIL=0

if [ ! -f "$CLEANUP" ]; then
  echo "ERROR: $CLEANUP not found" >&2
  exit 1
fi

# Track all temp repos created across tests so trap can clean them on
# unexpected exit (set -e fire / SIGINT / SIGTERM / SIGHUP). Without this,
# tests that fail mid-run leave /tmp/rite-pr-cleanup-test-* orphans.
TEST_REPOS=()
_cleanup_all_test_repos() {
  local repo
  for repo in "${TEST_REPOS[@]:-}"; do
    [ -z "$repo" ] && continue
    if [ -d "$repo" ]; then
      chmod -R u+rwX "$repo" 2>/dev/null || true
      rm -rf "$repo"
    fi
  done
}
trap '_cleanup_all_test_repos' EXIT
trap '_cleanup_all_test_repos; exit 130' INT
trap '_cleanup_all_test_repos; exit 143' TERM
trap '_cleanup_all_test_repos; exit 129' HUP

# -----------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------
pass() {
  PASS=$((PASS + 1))
  echo "  ✅ PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  ❌ FAIL: $1"
}

# Create a fresh temp git repository with an initial commit.
# Returns the absolute path on stdout.
make_temp_repo() {
  local tmp
  tmp=$(mktemp -d /tmp/rite-pr-cleanup-test-XXXXXX)
  TEST_REPOS+=("$tmp")
  (
    cd "$tmp"
    git init --quiet --initial-branch=main
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "init" > README.md
    git add README.md
    git commit --quiet -m "init"
  )
  echo "$tmp"
}

cleanup_temp_repo() {
  local repo="$1"
  if [ -n "$repo" ] && [ -d "$repo" ]; then
    chmod -R u+rwX "$repo" 2>/dev/null || true
    rm -rf "$repo"
  fi
}

# Count branches matching pr-*-cycle*
# `|| true` swallows grep's exit 1 when no matches — required under pipefail.
count_pr_cycle_branches() {
  local repo="$1"
  ( cd "$repo" && git for-each-ref --format='%(refname:short)' refs/heads/ \
    | { grep -E '^pr-[0-9]+-cycle[0-9]+$' || true; } | wc -l | tr -d ' ' )
}

# -----------------------------------------------------------------------
# T-01: 1 サイクル正常終了後の残置ゼロ
# Given: A reviewer-created worktree + branch in pr-N-cycleX form
# When: Cleanup runs after the cycle
# Then: Both the branch and worktree are removed
# -----------------------------------------------------------------------
echo "T-01: 1 サイクル正常終了後の残置ゼロ (AC-1)"
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  # Simulate reviewer creating a worktree with -b (the leak pattern)
  git worktree add --quiet -b pr-100-cycle1 .review-wt main >/dev/null 2>&1
)
# Run cleanup inside the test repo. NEVER run the cleanup outside the test
# repo — it would operate on the developer's actual repository and could
# delete legitimate `pr-*-cycle*` branches that exist there.
( cd "$TEST_REPO" && bash "$CLEANUP" >/dev/null 2>&1 )
remaining=$(count_pr_cycle_branches "$TEST_REPO")
if [ "$remaining" = "0" ]; then
  pass "T-01: 1 サイクル後にブランチが残らない"
else
  fail "T-01: $remaining branch(es) remaining (expected 0)"
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-02: 複数サイクル後の残置ゼロ
# Given: 3 cycles each created its own pr-N-cycleX branch + worktree
# When: Cleanup runs after the final cycle
# Then: All 3 branches are removed
# -----------------------------------------------------------------------
echo "T-02: 複数サイクル後の残置ゼロ (AC-2)"
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  git worktree add --quiet -b pr-200-cycle1 .wt-c1 main >/dev/null 2>&1
  git worktree add --quiet -b pr-200-cycle2 .wt-c2 main >/dev/null 2>&1
  git worktree add --quiet -b pr-200-cycle3 .wt-c3 main >/dev/null 2>&1
)
( cd "$TEST_REPO" && bash "$CLEANUP" >/dev/null 2>&1 )
remaining=$(count_pr_cycle_branches "$TEST_REPO")
if [ "$remaining" = "0" ]; then
  pass "T-02: 3 サイクル後にすべて削除された"
else
  fail "T-02: $remaining branch(es) remaining (expected 0)"
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-03: 異常終了時の回復経路
# Given: A previous cycle was interrupted, leaving a residual branch
#        (the worktree was rm -rf'd without `git worktree remove`)
# When: Cleanup runs at the next cycle start
# Then: The orphaned branch is deleted; prune handles dangling worktree metadata
# -----------------------------------------------------------------------
echo "T-03: 異常終了時の回復経路 (AC-3)"
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  git worktree add --quiet -b pr-300-cycle1 .wt-orphan main >/dev/null 2>&1
  # Simulate abnormal termination: directory deleted but worktree metadata + branch persist
  rm -rf .wt-orphan
)
# Capture stdout to verify the cleanup status line (asserts that `git worktree prune`
# completed successfully, which is the AC-3 核心ロジック — branch deletion alone is
# not sufficient evidence that the orphan worktree metadata was reclaimed).
t03_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
remaining=$(count_pr_cycle_branches "$TEST_REPO")
if [ "$remaining" = "0" ] && echo "$t03_output" | grep -q 'status=cleaned'; then
  pass "T-03: 異常終了後の orphan branch が削除され、status=cleaned が返った"
else
  fail "T-03: remaining=$remaining (expected 0), status check failed. Output: $t03_output"
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-04: 無関係ブランチの保護
# Given: User-created branches with similar-but-non-matching names exist
# When: Cleanup runs
# Then: Only branches matching the strict regex are deleted; others survive
# -----------------------------------------------------------------------
echo "T-04: 無関係ブランチの保護 (AC-4)"
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  # Match — should be deleted
  git branch pr-400-cycle1 main
  # Non-matches — must survive (test the regex boundary)
  git branch pr-400-cycle1-feature main           # suffix
  git branch feature/pr-400-cycle1 main           # prefix
  git branch pr-foo-cycle1 main                   # non-numeric N
  git branch pr-400-cycleA main                   # non-numeric X
  git branch pr-cycle1 main                       # missing N
  git branch user-pr-400-cycle1 main              # prefix
)
( cd "$TEST_REPO" && bash "$CLEANUP" >/dev/null 2>&1 )

# Verify the matching one is gone
matching=$(cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ \
  | { grep -E '^pr-400-cycle1$' || true; } | wc -l | tr -d ' ')

# Verify the non-matching ones all survive (6 in addition to main)
survivors=$(cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ \
  | { grep -v -E '^main$' || true; } | wc -l | tr -d ' ')

if [ "$matching" = "0" ] && [ "$survivors" = "6" ]; then
  pass "T-04: matching deleted, 6/6 non-matching branches survived"
else
  fail "T-04: matching=$matching (expect 0), survivors=$survivors (expect 6)"
  ( cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ ) | sed 's/^/    surviving: /'
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-05: Idempotent — re-running on a clean repo is a no-op
# -----------------------------------------------------------------------
echo "T-05: idempotent (no-op when nothing matches)"
TEST_REPO=$(make_temp_repo)
output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
if echo "$output" | grep -q 'status=noop'; then
  pass "T-05: noop status returned on clean repo"
else
  fail "T-05: expected status=noop, got: $output"
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
