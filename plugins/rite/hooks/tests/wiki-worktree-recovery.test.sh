#!/bin/bash
# Functional regression test for corrupt/orphaned .rite/wiki-worktree recovery.
#
# Reproduces the silent raw-source accumulation stall (Issue #1662): when the
# repository is relocated/copied, the wiki worktree's `.git` file keeps a stale
# `gitdir:` pointer to the old path, leaving `.rite/wiki-worktree` as a directory
# that exists on disk but is NOT a registered worktree. Before the fix:
#   - wiki-ingest-commit.sh hit `verify_worktree_branch ... || exit 1` and
#     hard-stopped (non-blocking upstream, so nobody saw the WARNING).
#   - wiki-worktree-setup.sh could not recover it either (`git worktree add`
#     aborts with "already exists" on the orphaned directory).
# Both scripts now self-heal. Unlike the sibling static-pin tests, this builds a
# real git fixture so the recovery cannot silently regress.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/../scripts"
COMMIT_SH="$SCRIPTS_DIR/wiki-ingest-commit.sh"
SETUP_SH="$SCRIPTS_DIR/wiki-worktree-setup.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

echo "=== wiki-worktree corrupt/orphaned recovery tests ==="
echo ""

for f in "$COMMIT_SH" "$SETUP_SH"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f not found" >&2
    exit 1
  fi
done

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

# Build a fixture repo with a dev branch + a wiki branch, then leave an orphaned
# .rite/wiki-worktree directory whose `.git` pointer is stale. Echoes the repo
# root on stdout.
make_fixture() {
  local root
  root="$WORK/repo"
  mkdir -p "$root"
  git -C "$root" init -q -b develop
  git -C "$root" config user.email "test@example.com"
  git -C "$root" config user.name "rite test"

  printf 'wiki:\n  enabled: true\n  branch_strategy: separate_branch\n  branch_name: wiki\n' \
    > "$root/rite-config.yml"
  printf '.rite/wiki-worktree/\n.rite/state/\n' > "$root/.gitignore"
  git -C "$root" add rite-config.yml .gitignore
  git -C "$root" commit -q -m "init develop"

  # wiki branch: tracks .rite/wiki/raw/ structure.
  git -C "$root" checkout -q --orphan wiki
  git -C "$root" rm -q -rf . >/dev/null 2>&1 || true
  mkdir -p "$root/.rite/wiki/raw/retrospectives"
  printf '# wiki\n' > "$root/.rite/wiki/index.md"
  : > "$root/.rite/wiki/raw/retrospectives/.gitkeep"
  git -C "$root" add .rite/wiki/index.md .rite/wiki/raw/retrospectives/.gitkeep
  git -C "$root" commit -q -m "init wiki"
  git -C "$root" checkout -q develop

  # Stage a pending raw source on the dev tree (untracked, as the trigger leaves it).
  mkdir -p "$root/.rite/wiki/raw/retrospectives"
  printf -- '---\ntype: retrospectives\nsource_ref: "issue-1662"\ningested: false\n---\n\nTest retrospective body.\n' \
    > "$root/.rite/wiki/raw/retrospectives/20260626T000000Z-issue-1662.md"

  # Orphaned worktree directory with a stale gitdir pointer (the relocation bug):
  # exists on disk, `git -C` cannot resolve it, and `git worktree list` omits it.
  mkdir -p "$root/.rite/wiki-worktree"
  printf 'gitdir: /nonexistent/relocated/.git/worktrees/wiki-worktree\n' \
    > "$root/.rite/wiki-worktree/.git"

  printf '%s\n' "$root"
}

# --- Sanity: the fixture really reproduces the broken precondition ---
WORK="$(mktemp -d)"
REPO="$(make_fixture)"

echo "TC-PRECONDITION: orphaned .rite/wiki-worktree is unresolvable and unregistered"
precond_ok=true
if git -C "$REPO/.rite/wiki-worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  precond_ok=false  # should FAIL to resolve
fi
if git -C "$REPO" worktree list --porcelain 2>/dev/null | grep -q "wiki-worktree"; then
  precond_ok=false  # should NOT be registered
fi
if [ "$precond_ok" = "true" ]; then
  pass "fixture reproduces corrupt + unregistered worktree"
else
  fail "fixture did not reproduce the broken precondition"
fi
echo ""

# --- TC-COMMIT-RECOVER: wiki-ingest-commit.sh self-heals and commits the raw ---
echo "TC-COMMIT-RECOVER: wiki-ingest-commit.sh recovers and commits pending raw"
wiki_before="$(git -C "$REPO" rev-parse wiki)"
set +e
commit_out="$(cd "$REPO" && bash "$COMMIT_SH" 2>commit_err.txt)"
commit_rc=$?
commit_err="$(cat "$REPO/commit_err.txt" 2>/dev/null || true)"
set -e
wiki_after="$(git -C "$REPO" rev-parse wiki)"

# rc 0 (push ok) or 4 (committed locally, push failed: no remote in fixture) both
# mean the raw landed on the wiki branch. The regression was a silent exit 1.
if { [ "$commit_rc" -eq 0 ] || [ "$commit_rc" -eq 4 ]; } && [ "$wiki_before" != "$wiki_after" ]; then
  pass "raw committed to wiki branch via self-heal (rc=$commit_rc)"
else
  fail "expected recovery+commit (rc 0/4, wiki advanced); got rc=$commit_rc, wiki_before=$wiki_before wiki_after=$wiki_after"
  echo "    --- stdout ---"; printf '%s\n' "$commit_out" | sed 's/^/    /'
  echo "    --- stderr ---"; printf '%s\n' "$commit_err" | sed 's/^/    /'
fi
echo ""

echo "TC-COMMIT-NOT-SILENT: a WARNING is emitted (no silent stall)"
if printf '%s' "$commit_err" | grep -q "自己回復\|wiki-worktree-setup.sh"; then
  pass "recovery WARNING surfaced on stderr"
else
  fail "no recovery WARNING — silent-failure regression"
fi
echo ""

echo "TC-COMMIT-RAW-ON-WIKI: committed raw is present on the wiki branch tree"
if git -C "$REPO" ls-tree -r --name-only wiki | grep -q "raw/retrospectives/20260626T000000Z-issue-1662.md"; then
  pass "raw source present on wiki branch"
else
  fail "raw source missing from wiki branch after recovery"
fi
echo ""

# --- TC-SETUP-RECOVER: wiki-worktree-setup.sh recovers the orphaned directory ---
# Fresh fixture so setup.sh faces the orphaned dir directly.
rm -rf "$WORK"; WORK="$(mktemp -d)"
REPO="$(make_fixture)"
echo "TC-SETUP-RECOVER: wiki-worktree-setup.sh repairs orphaned .rite/wiki-worktree"
set +e
setup_out="$(cd "$REPO" && bash "$SETUP_SH" 2>setup_err.txt)"
setup_rc=$?
set -e
if [ "$setup_rc" -eq 0 ] && git -C "$REPO/.rite/wiki-worktree" rev-parse --abbrev-ref HEAD >/dev/null 2>&1; then
  pass "setup repaired worktree into a resolvable git worktree (rc=$setup_rc)"
else
  fail "setup did not repair orphaned worktree (rc=$setup_rc)"
  printf '%s\n' "$setup_out" | sed 's/^/    out: /'
  cat "$REPO/setup_err.txt" 2>/dev/null | sed 's/^/    err: /'
fi
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
