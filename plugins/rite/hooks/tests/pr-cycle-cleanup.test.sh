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

# Isolate TMPDIR so the orphan-workdir GC (Step 3 of the cleanup script, #1311)
# scans an empty, test-owned directory instead of the developer's real /tmp.
# Without this, a real /tmp/rite-pr-create-* orphan on the host would make T-05
# (noop assertion) flaky and could even delete a developer's in-flight workdir.
# The workdir tests (T-06+) populate this directory explicitly. `mktemp -d
# /tmp/...` and make_temp_repo both use explicit /tmp paths, so they are
# unaffected by the TMPDIR export below.
WORKDIR_SCAN_TMP=$(mktemp -d /tmp/rite-pr-cleanup-tmpdir-XXXXXX)
TEST_REPOS+=("$WORKDIR_SCAN_TMP")
export TMPDIR="$WORKDIR_SCAN_TMP"

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
# T-04b: Issue #995 — reviewer variation branches (`pr-N-test` /
# `pr-N-experiment` / `pr-N-mutation` / `pr-N-verify` / `pr-N-check` /
# `pr-N-sandbox`) are cleaned up alongside `pr-N-cycleX`.
# Suffix variations (e.g. `pr-994-testing-suite`) must still survive.
# -----------------------------------------------------------------------
echo "T-04b: Issue #995 reviewer variation branches"
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  # Match — should be deleted (Issue #995 reviewer variation suffixes)
  git branch pr-994-test main
  git branch pr-995-experiment main
  git branch pr-996-mutation main
  git branch pr-997-verify main
  git branch pr-998-check main
  git branch pr-999-sandbox main
  # Non-matches — must survive
  git branch pr-994-testing-suite main             # suffix continuation
  git branch pr-994-testfile main                  # not exact-match
  git branch feature/pr-994-test main              # prefix
  git branch pr-994-experimental main              # suffix continuation
)
( cd "$TEST_REPO" && bash "$CLEANUP" >/dev/null 2>&1 )

# Verify all 6 reviewer variation branches are gone
matched_remaining=$(cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ \
  | { grep -cE '^pr-99[4-9]-(test|experiment|mutation|verify|check|sandbox)$' || true; })
# Verify the 4 non-matching branches survived (+ main = 5)
survivors=$(cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ \
  | { grep -v -E '^main$' || true; } | wc -l | tr -d ' ')

if [ "$matched_remaining" = "0" ] && [ "$survivors" = "4" ]; then
  pass "T-04b: 6/6 reviewer variations deleted, 4/4 non-matching branches survived"
else
  fail "T-04b: matched_remaining=$matched_remaining (expect 0), survivors=$survivors (expect 4)"
  ( cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ ) | sed 's/^/    surviving: /'
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-04c: Issue #995 cycle 1 — worktree-loop の regex sync を独立検証
# (test-reviewer 指摘: T-04b は bare branch のみで worktree-loop の regex が
# desync しても PASS する。worktree シナリオを追加し、worktree + branch のセット leak が
# cleanup されることを確認する)
# -----------------------------------------------------------------------
echo "T-04c: Issue #995 reviewer variation worktrees + branches (worktree-loop regex sync)"
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  # Match — should be cleaned up via worktree-loop (worktree first, then branch)
  git worktree add --quiet -b pr-994-test .wt-test main >/dev/null 2>&1
  git worktree add --quiet -b pr-995-experiment .wt-exp main >/dev/null 2>&1
  git worktree add --quiet -b pr-996-cycle1 .wt-cyc main >/dev/null 2>&1
  # Non-match worktree — must survive (suffix continuation in branch name)
  git worktree add --quiet -b pr-994-experimental .wt-survive main >/dev/null 2>&1
)
( cd "$TEST_REPO" && bash "$CLEANUP" >/dev/null 2>&1 )

# Verify the 3 reviewer-variation/cycle worktrees + branches are gone
matched_wt=$(cd "$TEST_REPO" && git worktree list --porcelain 2>/dev/null \
  | { grep -E '^branch refs/heads/pr-9(94|95|96)-(test|experiment|cycle1)$' || true; } | wc -l | tr -d ' ')
matched_br=$(cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ \
  | { grep -cE '^pr-9(94|95|96)-(test|experiment|cycle1)$' || true; })

# Verify the non-matching worktree + branch survived
survivor_wt=$(cd "$TEST_REPO" && git worktree list --porcelain 2>/dev/null \
  | { grep -F 'branch refs/heads/pr-994-experimental' || true; } | wc -l | tr -d ' ')

if [ "$matched_wt" = "0" ] && [ "$matched_br" = "0" ] && [ "$survivor_wt" = "1" ]; then
  pass "T-04c: 3/3 reviewer-variation worktrees+branches cleaned, 1/1 non-match worktree survived"
else
  fail "T-04c: matched_wt=$matched_wt (expect 0), matched_br=$matched_br (expect 0), survivor_wt=$survivor_wt (expect 1)"
  ( cd "$TEST_REPO" && git worktree list ) | sed 's/^/    worktree: /'
  ( cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ ) | sed 's/^/    branch: /'
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
# T-06: orphan workdir reaping (refs #1311)
# Given: aged `rite-pr-create-*` workdirs (one empty = after-(A) orphan, one with
#        files = after-(B) orphan) older than the age threshold exist in TMPDIR
# When: Cleanup runs
# Then: Both are reaped via rm -rf and the status line reports workdirs=2
# Uses `touch -t 202001010000` (POSIX-portable, far older than 24h) to backdate
# the directory mtime AFTER writing contents (writing a file bumps the dir mtime).
# -----------------------------------------------------------------------
echo "T-06: 古い orphan workdir 回収 (refs #1311)"
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* 2>/dev/null || true
mkdir -p "$WORKDIR_SCAN_TMP/rite-pr-create-old1"
echo "stale title" > "$WORKDIR_SCAN_TMP/rite-pr-create-old1/pr_title.txt"  # after-(B) orphan: has files
mkdir -p "$WORKDIR_SCAN_TMP/rite-pr-create-old2"                          # after-(A) orphan: empty
touch -t 202001010000 "$WORKDIR_SCAN_TMP/rite-pr-create-old1" "$WORKDIR_SCAN_TMP/rite-pr-create-old2"
TEST_REPO=$(make_temp_repo)
t06_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
if [ ! -d "$WORKDIR_SCAN_TMP/rite-pr-create-old1" ] && [ ! -d "$WORKDIR_SCAN_TMP/rite-pr-create-old2" ] \
   && echo "$t06_output" | grep -q 'status=cleaned' && echo "$t06_output" | grep -q 'workdirs=2'; then
  pass "T-06: 古い orphan workdir 2 件 (空 + 非空) が回収され workdirs=2"
else
  fail "T-06: old1=$([ -d "$WORKDIR_SCAN_TMP/rite-pr-create-old1" ] && echo present || echo gone), old2=$([ -d "$WORKDIR_SCAN_TMP/rite-pr-create-old2" ] && echo present || echo gone). Output: $t06_output"
fi
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-07: age 未満の workdir は保護 (in-flight 誤回収防止) (refs #1311)
# Given: a freshly-created `rite-pr-create-*` workdir (mtime = now) exists
# When: Cleanup runs
# Then: The workdir survives (age guard) and status=noop (nothing reaped)
# This is the core safety assertion: a concurrent session's in-flight workdir is
# never reaped by another session's cleanup.
# -----------------------------------------------------------------------
echo "T-07: age 未満の workdir は保護 (in-flight 誤回収防止) (refs #1311)"
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* 2>/dev/null || true
mkdir -p "$WORKDIR_SCAN_TMP/rite-pr-create-fresh"  # just created -> mtime now -> must survive
TEST_REPO=$(make_temp_repo)
t07_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
if [ -d "$WORKDIR_SCAN_TMP/rite-pr-create-fresh" ] && echo "$t07_output" | grep -q 'status=noop'; then
  pass "T-07: age 未満の workdir が保護され status=noop"
else
  fail "T-07: fresh=$([ -d "$WORKDIR_SCAN_TMP/rite-pr-create-fresh" ] && echo present || echo gone). Output: $t07_output"
fi
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-08: 無関係 prefix のディレクトリは age 超過でも保護 (refs #1311)
# Given: an aged matching `rite-pr-create-victim` plus aged non-matching dirs
#        (`rite-pr-cleanup-test-*` — the test-repo prefix — and `unrelated-dir`)
# When: Cleanup runs
# Then: Only `rite-pr-create-*` is reaped; the name-glob boundary protects others
# -----------------------------------------------------------------------
echo "T-08: 無関係 prefix のディレクトリは age 超過でも保護 (refs #1311)"
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* "$WORKDIR_SCAN_TMP/rite-pr-cleanup-test-xyz" "$WORKDIR_SCAN_TMP/unrelated-dir" 2>/dev/null || true
mkdir -p "$WORKDIR_SCAN_TMP/rite-pr-create-victim"      # match -> reaped
mkdir -p "$WORKDIR_SCAN_TMP/rite-pr-cleanup-test-xyz"   # different prefix -> survive
mkdir -p "$WORKDIR_SCAN_TMP/unrelated-dir"             # unrelated -> survive
touch -t 202001010000 "$WORKDIR_SCAN_TMP/rite-pr-create-victim" "$WORKDIR_SCAN_TMP/rite-pr-cleanup-test-xyz" "$WORKDIR_SCAN_TMP/unrelated-dir"
TEST_REPO=$(make_temp_repo)
( cd "$TEST_REPO" && bash "$CLEANUP" >/dev/null 2>&1 )
if [ ! -d "$WORKDIR_SCAN_TMP/rite-pr-create-victim" ] \
   && [ -d "$WORKDIR_SCAN_TMP/rite-pr-cleanup-test-xyz" ] \
   && [ -d "$WORKDIR_SCAN_TMP/unrelated-dir" ]; then
  pass "T-08: rite-pr-create-* のみ回収、無関係 prefix は保護"
else
  fail "T-08: victim=$([ -d "$WORKDIR_SCAN_TMP/rite-pr-create-victim" ] && echo present || echo gone), test-xyz=$([ -d "$WORKDIR_SCAN_TMP/rite-pr-cleanup-test-xyz" ] && echo present || echo gone), unrelated=$([ -d "$WORKDIR_SCAN_TMP/unrelated-dir" ] && echo present || echo gone)"
fi
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* "$WORKDIR_SCAN_TMP/rite-pr-cleanup-test-xyz" "$WORKDIR_SCAN_TMP/unrelated-dir" 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-09: --dry-run は orphan workdir を削除しない (refs #1311)
# Given: an aged matching `rite-pr-create-*` workdir exists
# When: Cleanup runs with --dry-run
# Then: The workdir survives and a `[dry-run] would reap ...` line is printed
# -----------------------------------------------------------------------
echo "T-09: --dry-run は orphan workdir を削除しない (refs #1311)"
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* 2>/dev/null || true
mkdir -p "$WORKDIR_SCAN_TMP/rite-pr-create-dry"
touch -t 202001010000 "$WORKDIR_SCAN_TMP/rite-pr-create-dry"
TEST_REPO=$(make_temp_repo)
t09_output=$( cd "$TEST_REPO" && bash "$CLEANUP" --dry-run 2>&1 )
if [ -d "$WORKDIR_SCAN_TMP/rite-pr-create-dry" ] && echo "$t09_output" | grep -q 'would reap orphan workdir'; then
  pass "T-09: dry-run は削除せず候補をリスト"
else
  fail "T-09: dry=$([ -d "$WORKDIR_SCAN_TMP/rite-pr-create-dry" ] && echo present || echo gone). Output: $t09_output"
fi
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-10: find wholesale 失敗が silent でない (refs #1311)
# Given: TMPDIR が存在しないパスを指し、Step 3 の find が wholesale 失敗する
# When: Cleanup runs
# Then: find 失敗は WARNING + errors++ で surface され status=failed になる
#       (process substitution の rc 非伝播による silent no-op 化を防ぐ回帰テスト)
# TMPDIR override はこの 1 実行に限定する。cleanup script の mktemp は /tmp 直書きのため
# bogus TMPDIR の影響を受けず、find の base 走査のみが失敗する。
# -----------------------------------------------------------------------
echo "T-10: find wholesale 失敗が silent でない (refs #1311)"
TEST_REPO=$(make_temp_repo)
t10_output=$( cd "$TEST_REPO" && TMPDIR=/nonexistent/rite-pr-cleanup-does-not-exist bash "$CLEANUP" 2>&1 )
if echo "$t10_output" | grep -q 'status=failed' \
   && echo "$t10_output" | grep -q 'find による orphan workdir 走査が失敗'; then
  pass "T-10: find 失敗が WARNING + status=failed で surface される (silent 化しない)"
else
  fail "T-10: status=failed と find WARNING を期待。Output: $t10_output"
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
