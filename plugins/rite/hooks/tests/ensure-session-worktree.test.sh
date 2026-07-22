#!/bin/bash
# Tests for ensure_session_worktree (lib/worktree-git.sh, #1676) — the shared
# bash-side gate that detects + reconstructs a missing session worktree at a
# flow ENTRY path so review/iterate/fix never silently degrade onto develop.
#
#   T-01 / AC-1: branch local ∧ worktree absent → reconstructed (worktree added)
#   T-04 / AC-4: git worktree add fails → failed (rc 1, NO silent fallback, no residue)
#   T-05 / AC-5: branch absent everywhere → branch_absent (no reconstruction)
#   Plus: disabled / already_in / reenter / residue / branch_other_worktree /
#         remote-only reconstruct / explicit --branch path / marker path=/other=
#         fields / arg error / stdout discipline.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

HELPER="$SCRIPT_DIR/../scripts/lib/worktree-git.sh"

# Sandbox cleanup (suite convention — see worktree-foreign-cwd.test.sh).
cleanup_dirs=()
cleanup() { for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT

# Build a bare "remote" + a main clone with multi_session enabled. Sets the
# global REPO_MAIN to the main checkout path and registers the sandbox root in
# cleanup_dirs. Run in PARENT scope (NOT `$(setup_repo)`) so cleanup_dirs+= and
# REPO_MAIN propagate. Creates: develop (pushed), local branch fix/issue-42-foo,
# remote-only branch feat/issue-77-bar.
REPO_MAIN=""
setup_repo() {
  local root
  root=$(make_plain_sandbox) || return 1
  cleanup_dirs+=("$root")
  git init -q --bare "$root/remote.git"
  git init -q "$root/main"
  (
    cd "$root/main" || exit 1
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
  REPO_MAIN="$root/main"
}

# Run the helper from <dir> and print the bare WT_ENSURE case token.
ens_case() {
  local dir="$1"; shift
  ( cd "$dir" && bash "$HELPER" ensure-session-worktree "$@" 2>/dev/null ) \
    | sed -n 's/.*WT_ENSURE=\([a-z_]*\).*/\1/p'
}
# Run the helper from <dir> and print the value of a marker field (e.g. path, other).
ens_field() {
  local dir="$1" field="$2"; shift 2
  ( cd "$dir" && bash "$HELPER" ensure-session-worktree "$@" 2>/dev/null ) \
    | sed -n "s/.*; ${field}=\([^;]*\).*/\1/p" | head -1
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
setup_repo; M="$REPO_MAIN"
printf 'multi_session:\n  enabled: false\n  worktree_base: ".rite/worktrees"\n' > "$M/rite-config.yml"
assert "TC-1 disabled token" "disabled" "$(ens_case "$M" --issue 42)"
assert "TC-1 rc=0" "0" "$(ens_rc "$M" --issue 42)"

# --- TC-2 (T-05 / AC-5): branch absent → branch_absent, no reconstruction ---
echo "=== TC-2 (T-05/AC-5): branch nowhere → branch_absent, no worktree created ==="
setup_repo; M="$REPO_MAIN"
assert "TC-2 branch_absent token" "branch_absent" "$(ens_case "$M" --issue 99)"
assert "TC-2 no worktree created" "no" "$(wt_registered "$M" 99)"

# --- TC-3 (T-01 / AC-1): local branch ∧ worktree absent → reconstructed ---
echo "=== TC-3 (T-01/AC-1): local branch, worktree absent → reconstructed ==="
setup_repo; M="$REPO_MAIN"
assert "TC-3 reconstructed token" "reconstructed" "$(ens_case "$M" --issue 42)"
assert "TC-3 worktree registered" "yes" "$(wt_registered "$M" 42)"

# --- TC-3b: explicit --branch (the form pr-review.md / fix.md actually use) ---
echo "=== TC-3b: explicit --branch reconstructed (caller invocation form) ==="
setup_repo; M="$REPO_MAIN"
assert "TC-3b reconstructed token (explicit branch)" "reconstructed" \
  "$(ens_case "$M" --issue 42 --branch fix/issue-42-foo)"
assert "TC-3b worktree registered" "yes" "$(wt_registered "$M" 42)"

# --- TC-4: remote-only branch → reconstructed (fetch + add --track) ---
echo "=== TC-4: remote-only branch → reconstructed ==="
setup_repo; M="$REPO_MAIN"
assert "TC-4 reconstructed token" "reconstructed" "$(ens_case "$M" --issue 77)"
assert "TC-4 worktree registered" "yes" "$(wt_registered "$M" 77)"

# --- TC-5: already_in (run from inside the worktree) ---
echo "=== TC-5: cwd inside worktree → already_in ==="
setup_repo; M="$REPO_MAIN"
ens_case "$M" --issue 42 >/dev/null   # create+register it first
assert "TC-5 already_in token" "already_in" "$(ens_case "$M/.rite/worktrees/issue-42" --issue 42)"

# --- TC-6: reenter (registered, cwd elsewhere) + path= field is load-bearing ---
echo "=== TC-6: registered, cwd=main → reenter, path= points at the worktree ==="
setup_repo; M="$REPO_MAIN"
ens_case "$M" --issue 42 >/dev/null
assert "TC-6 reenter token" "reenter" "$(ens_case "$M" --issue 42)"
# path= is the value the caller feeds to EnterWorktree — assert it resolves to the issue worktree.
assert "TC-6 path= ends with .rite/worktrees/issue-42" "yes" \
  "$(case "$(ens_field "$M" path --issue 42)" in */.rite/worktrees/issue-42) echo yes ;; *) echo no ;; esac)"

# --- TC-7: residue (dir exists at path, not a registered worktree) ---
echo "=== TC-7: stale dir at path, not registered → residue ==="
setup_repo; M="$REPO_MAIN"
mkdir -p "$M/.rite/worktrees/issue-42"; echo junk > "$M/.rite/worktrees/issue-42/junk"
assert "TC-7 residue token" "residue" "$(ens_case "$M" --issue 42)"

# --- TC-8: branch checked out in ANOTHER worktree → branch_other_worktree (+ other=, no new wt) ---
echo "=== TC-8: branch in a different worktree → branch_other_worktree ==="
setup_repo; M="$REPO_MAIN"
git -C "$M" worktree add -q "$M/elsewhere-42" fix/issue-42-foo >/dev/null 2>&1
assert "TC-8 branch_other_worktree token" "branch_other_worktree" "$(ens_case "$M" --issue 42)"
# other= must surface the conflicting worktree path (recover.md table 「other= のパスを表示」契約).
assert "TC-8 other= ends with elsewhere-42" "yes" \
  "$(case "$(ens_field "$M" other --issue 42)" in */elsewhere-42) echo yes ;; *) echo no ;; esac)"
# Must NOT create the canonical issue-42 worktree (no silent reconstruction over a conflict).
assert "TC-8 canonical issue-42 worktree not created" "no" \
  "$(git -C "$M" worktree list --porcelain | grep -qE '/\.rite/worktrees/issue-42($|/| )' && echo yes || echo no)"

# --- TC-9 (T-04 / AC-4): git worktree add fails → failed (rc 1, NO fallback, no residue) ---
echo "=== TC-9 (T-04/AC-4): reconstruction fails → failed, rc=1, no partial worktree ==="
setup_repo; M="$REPO_MAIN"
rm -rf "$M/.rite"; mkdir -p "$M/.rite"; printf 'blocker' > "$M/.rite/worktrees"  # base is a FILE
assert "TC-9 failed token" "failed" "$(ens_case "$M" --issue 42)"
assert "TC-9 rc=1" "1" "$(ens_rc "$M" --issue 42)"
# AC-4 core: no silent fallback means no half-built worktree is registered.
assert "TC-9 no worktree registered after failure" "no" "$(wt_registered "$M" 42)"

# --- TC-10: argument error (missing / non-numeric --issue) → rc 2 ---
echo "=== TC-10: missing / non-numeric --issue → rc 2 ==="
setup_repo; M="$REPO_MAIN"
assert "TC-10 rc=2 (missing --issue)" "2" "$(ens_rc "$M")"
assert "TC-10 rc=2 (non-numeric --issue)" "2" "$(ens_rc "$M" --issue abc)"

# --- TC-11: stdout discipline — exactly ONE line, the marker (git chatter to stderr) ---
echo "=== TC-11: stdout is exactly one WT_ENSURE marker line on reconstruct ==="
setup_repo; M="$REPO_MAIN"
stdout_lines=$( ( cd "$M" && bash "$HELPER" ensure-session-worktree --issue 42 2>/dev/null ) | grep -c .)
assert "TC-11 single stdout line" "1" "$stdout_lines"

# --- TC-12 (T-01/AC-1, #1943): settings.local.json present → copied into reconstructed worktree ---
echo "=== TC-12 (T-01/AC-1, #1943): settings.local.json present → copied to worktree ==="
setup_repo; M="$REPO_MAIN"
mkdir -p "$M/.claude"; echo '{"enabledPlugins":{"rite@rite-marketplace":false}}' > "$M/.claude/settings.local.json"
ens_case "$M" --issue 42 >/dev/null
assert "TC-12 settings.local.json copied" "yes" \
  "$([ -f "$M/.rite/worktrees/issue-42/.claude/settings.local.json" ] && echo yes || echo no)"
assert "TC-12 copied content matches" "yes" \
  "$(diff -q "$M/.claude/settings.local.json" "$M/.rite/worktrees/issue-42/.claude/settings.local.json" >/dev/null 2>&1 && echo yes || echo no)"

# --- TC-13 (T-02/AC-2, #1943): settings.local.json absent → nothing extra created ---
echo "=== TC-13 (T-02/AC-2, #1943): settings.local.json absent → no file/dir created in worktree ==="
setup_repo; M="$REPO_MAIN"
ens_case "$M" --issue 42 >/dev/null
assert "TC-13 no settings.local.json created" "no" \
  "$([ -e "$M/.rite/worktrees/issue-42/.claude/settings.local.json" ] && echo yes || echo no)"
assert "TC-13 no .claude dir created" "no" \
  "$([ -e "$M/.rite/worktrees/issue-42/.claude" ] && echo yes || echo no)"

print_summary "ensure-session-worktree.test.sh" \
  "ensure_session_worktree contract changed — sync lib/worktree-git.sh and the recover.md WT_ENSURE table"
