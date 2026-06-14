#!/bin/bash
# Tests for worktree-git.sh non-fast-forward push retry (§9).
#
# Verifies:
#   AC-1: a push whose remote branch was advanced concurrently succeeds via
#         fetch + rebase + push retry (rc 0).
#   AC-2: a rebase-unmergeable conflict aborts and returns the existing rc=4.
#   non-NFF (auth/network-shaped) failure fails immediately with rc=4 (1 attempt,
#         no retry) — the prior behavior is preserved.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
# shellcheck source=../scripts/lib/worktree-git.sh
source "$SCRIPT_DIR/../scripts/lib/worktree-git.sh"

GIT="git -c user.email=t@test.local -c user.name=test -c commit.gpgsign=false"

cleanup_dirs=()
cleanup() { local d; for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

# Build: a bare remote with branch `wiki`, plus two clones (under-test + rival).
setup_remote() {
  local base; base=$(make_plain_sandbox)
  cleanup_dirs+=("$base")
  $GIT init -q --bare "$base/remote.git"
  $GIT init -q -b wiki "$base/seed"
  ( cd "$base/seed" && echo "line1" > shared.txt && $GIT add shared.txt && $GIT commit -qm seed && $GIT push -q "$base/remote.git" wiki ) >/dev/null 2>&1
  $GIT clone -q -b wiki "$base/remote.git" "$base/under_test" >/dev/null 2>&1
  $GIT clone -q -b wiki "$base/remote.git" "$base/rival" >/dev/null 2>&1
  # worktree_commit_push commits via plain `git commit` (no -c flags), so the
  # under-test clone needs a persistent identity — CI runners have no global
  # git user.name/email. (rival/seed use the $GIT alias and don't need it.)
  for clone in under_test rival; do
    git -C "$base/$clone" config user.email t@test.local
    git -C "$base/$clone" config user.name test
    git -C "$base/$clone" config commit.gpgsign false
  done
  printf '%s' "$base"
}

# Advance origin/wiki from the rival clone (simulates a concurrent session push).
rival_push() {
  local base="$1" file="$2" content="$3"
  ( cd "$base/rival" && $GIT pull -q --ff-only origin wiki && printf '%s\n' "$content" >> "$file" \
      && $GIT add "$file" && $GIT commit -qm "rival $file" && $GIT push -q origin wiki ) >/dev/null 2>&1
}

echo "=== TC-1 (AC-1): NFF push succeeds via fetch+rebase+retry (rc 0) ==="
BASE=$(setup_remote)
rival_push "$BASE" rival.txt "rival-change"          # origin/wiki now ahead
# under_test adds a NON-conflicting new file and pushes via the helper.
echo "ut-content" > "$BASE/under_test/ut.txt"
rc=0
out=$(worktree_commit_push "$BASE/under_test" wiki "ut commit" ut.txt 2>/tmp/wtg1.err) || rc=$?
assert "TC-1 rc 0 (NFF resolved)" "0" "$rc"
case "$out" in *"push=ok"*) pass "TC-1 push=ok" ;; *) fail "TC-1 status line: $out" ;; esac
# The rival's file must be present (rebase pulled it in) along with ours.
assert "TC-1 rival change rebased in" "1" "$( [ -f "$BASE/under_test/rival.txt" ] && echo 1 || echo 0 )"
if grep -qiE 'non-fast-forward|rejected' /tmp/wtg1.err; then pass "TC-1 NFF retry path exercised (WARNING emitted)"; else fail "TC-1 expected NFF WARNING"; fi

echo "=== TC-2 (AC-2): rebase conflict aborts → rc 4 ==="
BASE=$(setup_remote)
rival_push "$BASE" shared.txt "rival-conflicting-line"   # rival changes shared.txt
# under_test changes the SAME file → rebase will conflict.
echo "ut-conflicting-line" >> "$BASE/under_test/shared.txt"
rc=0
worktree_commit_push "$BASE/under_test" wiki "ut conflict" shared.txt >/tmp/wtg2.out 2>/tmp/wtg2.err || rc=$?
assert "TC-2 rc 4 (rebase conflict → existing contract)" "4" "$rc"
if grep -qiE 'rebase.*(failed|conflict)|aborted' /tmp/wtg2.err; then pass "TC-2 rebase-abort WARNING emitted"; else fail "TC-2 expected rebase-abort WARNING: $(cat /tmp/wtg2.err)"; fi
# After abort the worktree must NOT be left mid-rebase.
assert "TC-2 no rebase in progress left" "0" "$( [ -d "$BASE/under_test/.git/rebase-merge" ] || [ -d "$BASE/under_test/.git/rebase-apply" ] && echo 1 || echo 0 )"

echo "=== TC-3: non-NFF failure fails immediately with rc 4 (no retry) ==="
BASE=$(setup_remote)
# Point origin at a non-existent path → push fails for a non-NFF reason.
( cd "$BASE/under_test" && $GIT remote set-url origin "$BASE/does-not-exist.git" ) >/dev/null 2>&1
echo "x" > "$BASE/under_test/ut2.txt"
rc=0
worktree_commit_push "$BASE/under_test" wiki "ut nonnff" ut2.txt >/tmp/wtg3.out 2>/tmp/wtg3.err || rc=$?
assert "TC-3 rc 4 (non-NFF)" "4" "$rc"
if grep -qiE 'non-fast-forward' /tmp/wtg3.err; then fail "TC-3 must NOT take NFF retry path"; else pass "TC-3 no NFF retry (immediate fail)"; fi

rm -f /tmp/wtg1.err /tmp/wtg2.out /tmp/wtg2.err /tmp/wtg3.out /tmp/wtg3.err 2>/dev/null || true
print_summary "$(basename "$0")" \
  "Drift hint: worktree-git.sh §9 — NFF push retry (fetch+rebase+push x3); rebase conflict → rc4; non-NFF → immediate rc4; 0/3/4/5 contract unchanged."
