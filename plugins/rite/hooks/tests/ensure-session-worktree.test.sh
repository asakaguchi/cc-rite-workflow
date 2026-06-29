#!/bin/bash
# Tests for ensure_session_worktree (lib/worktree-git.sh, #1676) — the shared
# bash-side gate that detects + reconstructs a missing session worktree at a
# flow ENTRY path so review/iterate/fix never silently degrade onto develop.
#
#   T-01 / AC-1: branch local ∧ worktree absent → reconstructed (worktree added)
#   T-04 / AC-4: git worktree add fails → failed (rc 1, NO silent fallback)
#   T-05 / AC-5: branch absent everywhere → branch_absent (no reconstruction)
#   Plus: disabled / already_in / reenter / residue / branch_other_worktree /
#         remote-only reconstruct / arg error / stdout discipline.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

HELPER="$SCRIPT_DIR/../scripts/lib/worktree-git.sh"

# Build a bare "remote" + a main clone with multi_session enabled. Echoes the
# main checkout path. Creates: develop (pushed), local branch fix/issue-42-foo,
# remote-only branch feat/issue-77-bar.
setup_repo() {
  local root main
  root=$(make_plain_sandbox) || return 1
  git init -q --bare "$root/remote.git"
  git init -q "$root/main"
  main="$root/main"
  (
    cd "$main" || exit 1
    git config user.email t@t; git config user.name t
    git remote add origin ../remote.git
    printf 'multi_session:\n  enabled: true\n  worktree_base: ".rite/worktrees"\n' > rite-config.yml
    git add -A; git commit -qm init
    git branch -m develop
    git push -q -u origin develop
    git branch fix/issue-42-foo develop            # local-only feature branch
    git checkout -q -b feat/issue-77-bar develop
    echo x > x.txt; git add -A; git commit -qm work
    git push -q -u origin feat/issue-77-bar
    git checkout -q develop
    git branch -D feat/issue-77-bar                # issue-77 now remote-only
  ) >/dev/null 2>&1 || return 1
  echo "$main"
}

# Run the helper from <dir> and print the bare WT_ENSURE case token.
ens_case() {
  local dir="$1"; shift
  ( cd "$dir" && bash "$HELPER" ensure-session-worktree "$@" 2>/dev/null ) \
    | sed -n 's/.*WT_ENSURE=\([a-z_]*\).*/\1/p'
}
# Run the helper from <dir> and print its exit code.
ens_rc() {
  local dir="$1"; shift
  ( cd "$dir" && bash "$HELPER" ensure-session-worktree "$@" >/dev/null 2>&1 ); echo $?
}
# "yes"/"no": is a worktree for issue-<N> registered in <main>?
wt_registered() {
  git -C "$1" worktree list --porcelain 2>/dev/null | grep -qE "/issue-$2($|/| )" && echo yes || echo no
}

# --- TC-1: disabled (multi_session.enabled: false) ---
echo "=== TC-1: enabled:false → disabled (legacy single-tree, unchanged) ==="
M=$(setup_repo)
printf 'multi_session:\n  enabled: false\n  worktree_base: ".rite/worktrees"\n' > "$M/rite-config.yml"
assert "TC-1 disabled token" "disabled" "$(ens_case "$M" --issue 42)"
assert "TC-1 rc=0" "0" "$(ens_rc "$M" --issue 42)"
# restore enabled for any reuse
printf 'multi_session:\n  enabled: true\n  worktree_base: ".rite/worktrees"\n' > "$M/rite-config.yml"

# --- TC-2 (T-05 / AC-5): branch absent → branch_absent, no reconstruction ---
echo "=== TC-2 (T-05/AC-5): branch nowhere → branch_absent, no worktree created ==="
M=$(setup_repo)
assert "TC-2 branch_absent token" "branch_absent" "$(ens_case "$M" --issue 99)"
assert "TC-2 no worktree created" "no" "$(wt_registered "$M" 99)"

# --- TC-3 (T-01 / AC-1): local branch ∧ worktree absent → reconstructed ---
echo "=== TC-3 (T-01/AC-1): local branch, worktree absent → reconstructed ==="
M=$(setup_repo)
assert "TC-3 reconstructed token" "reconstructed" "$(ens_case "$M" --issue 42)"
assert "TC-3 worktree registered" "yes" "$(wt_registered "$M" 42)"

# --- TC-4: remote-only branch → reconstructed (fetch + add --track) ---
echo "=== TC-4: remote-only branch → reconstructed ==="
M=$(setup_repo)
assert "TC-4 reconstructed token" "reconstructed" "$(ens_case "$M" --issue 77)"
assert "TC-4 worktree registered" "yes" "$(wt_registered "$M" 77)"

# --- TC-5: already_in (run from inside the worktree) ---
echo "=== TC-5: cwd inside worktree → already_in ==="
M=$(setup_repo)
ens_case "$M" --issue 42 >/dev/null   # create+register it first
assert "TC-5 already_in token" "already_in" "$(ens_case "$M/.rite/worktrees/issue-42" --issue 42)"

# --- TC-6: reenter (registered, cwd elsewhere) ---
echo "=== TC-6: registered, cwd=main → reenter ==="
M=$(setup_repo)
ens_case "$M" --issue 42 >/dev/null
assert "TC-6 reenter token" "reenter" "$(ens_case "$M" --issue 42)"

# --- TC-7: residue (dir exists at path, not a registered worktree) ---
echo "=== TC-7: stale dir at path, not registered → residue ==="
M=$(setup_repo)
mkdir -p "$M/.rite/worktrees/issue-42"; echo junk > "$M/.rite/worktrees/issue-42/junk"
assert "TC-7 residue token" "residue" "$(ens_case "$M" --issue 42)"

# --- TC-8: branch checked out in ANOTHER worktree → branch_other_worktree ---
echo "=== TC-8: branch in a different worktree → branch_other_worktree ==="
M=$(setup_repo)
git -C "$M" worktree add -q "$M/../elsewhere-42" fix/issue-42-foo >/dev/null 2>&1
assert "TC-8 branch_other_worktree token" "branch_other_worktree" "$(ens_case "$M" --issue 42)"

# --- TC-9 (T-04 / AC-4): git worktree add fails → failed (rc 1, NO fallback) ---
echo "=== TC-9 (T-04/AC-4): reconstruction fails → failed, rc=1 ==="
M=$(setup_repo)
rm -rf "$M/.rite"; mkdir -p "$M/.rite"; printf 'blocker' > "$M/.rite/worktrees"  # base is a FILE
assert "TC-9 failed token" "failed" "$(ens_case "$M" --issue 42)"
assert "TC-9 rc=1" "1" "$(ens_rc "$M" --issue 42)"

# --- TC-10: argument error (missing --issue) → rc 2 ---
echo "=== TC-10: missing --issue → rc 2 ==="
M=$(setup_repo)
assert "TC-10 rc=2" "2" "$(ens_rc "$M")"

# --- TC-11: stdout discipline — exactly ONE line, the marker (git chatter to stderr) ---
echo "=== TC-11: stdout is exactly one WT_ENSURE marker line on reconstruct ==="
M=$(setup_repo)
stdout_lines=$( ( cd "$M" && bash "$HELPER" ensure-session-worktree --issue 42 2>/dev/null ) | grep -c .)
assert "TC-11 single stdout line" "1" "$stdout_lines"

print_summary "ensure-session-worktree.test.sh" \
  "ensure_session_worktree contract changed — sync lib/worktree-git.sh and the resume.md WT_ENSURE table"
