#!/bin/bash
# Tests for hooks/scripts/wiki-worktree-commit.sh (Issue #1719)
#
# The script stages + commits + pushes pending changes in the .rite/wiki-worktree
# worktree. It has a git push side effect, so the happy-path test wires `origin`
# to a LOCAL bare repo (AC-4): the push lands in that bare repo, never touching a
# real remote or the network. The remaining cases pin the invocation contract and
# the early-exit reasons (wiki-disabled / worktree-missing / no-pending / dry-run).
#
# Convention: mktemp sandbox, no gh, no network, GNU/BSD portable, commit.gpgsign
# disabled locally so fixtures commit under a global signing config.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../scripts/wiki-worktree-commit.sh"

echo "=== wiki-worktree-commit.sh tests ==="

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT not found" >&2
  exit 1
fi

SANDBOXES=()
cleanup() {
  local d
  for d in "${SANDBOXES[@]:-}"; do
    # Detach any worktrees before rm so no stale admin entries leak into $HOME.
    [ -n "$d" ] && [ -d "$d" ] && git -C "$d" worktree prune 2>/dev/null || true
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# Build a git repo with rite-config.yml (wiki enabled|disabled). Echoes the path.
# The caller MUST register the returned path in SANDBOXES from the PARENT shell —
# this helper runs inside a $(...) command substitution, so a `SANDBOXES+=` here
# would be lost with the subshell (the pitfall _test-helpers.sh documents for
# make_sandbox). Git steps are &&-chained and HEAD is asserted so a broken fixture
# fails loudly instead of returning a half-built repo that silently passes the
# skip-path tests.
new_repo() {
  local enabled="$1" repo
  repo="$(mktemp -d)"
  git -C "$repo" init -q \
    && git -C "$repo" config user.email t@test.local \
    && git -C "$repo" config user.name test \
    && git -C "$repo" config commit.gpgsign false \
    || { echo "FAIL: new_repo git init/config failed" >&2; exit 1; }
  printf 'wiki:\n  enabled: %s\n  branch_name: wiki\n' "$enabled" > "$repo/rite-config.yml"
  git -C "$repo" add rite-config.yml \
    && git -C "$repo" commit -q -m init \
    && git -C "$repo" rev-parse HEAD >/dev/null 2>&1 \
    || { echo "FAIL: new_repo fixture commit failed" >&2; exit 1; }
  printf '%s' "$repo"
}

# Add a `wiki` branch, a local bare "origin", and a wiki-worktree on it.
# Called directly (not in $(...)) so `SANDBOXES+=` reaches the parent and `exit 1`
# aborts the whole run. Git steps are &&-chained and origin/wiki is asserted so a
# failed push cannot degrade the happy-path "advanced" check into an empty-string
# comparison that passes without a real push.
setup_wiki_worktree() {
  local repo="$1" bare
  bare="$(mktemp -d)"; SANDBOXES+=("$bare")
  git -C "$repo" branch wiki \
    && git -C "$bare" init -q --bare \
    && git -C "$repo" remote add origin "$bare" \
    && git -C "$repo" push -q origin wiki \
    && git -C "$repo" worktree add -q "$repo/.rite/wiki-worktree" wiki \
    && git -C "$repo" rev-parse origin/wiki >/dev/null 2>&1 \
    || { echo "FAIL: setup_wiki_worktree failed (branch/bare/remote/push/worktree)" >&2; exit 1; }
}

# Drop an untracked page under the worktree's .rite/wiki tree.
add_pending() {
  local repo="$1"
  mkdir -p "$repo/.rite/wiki-worktree/.rite/wiki/pages"
  printf '# test page\n' > "$repo/.rite/wiki-worktree/.rite/wiki/pages/test.md"
}

run_in() { local repo="$1"; shift; ( cd "$repo" && bash "$SCRIPT" "$@" ) 2>/dev/null; }
rc_in()  { local repo="$1"; shift; ( cd "$repo" && bash "$SCRIPT" "$@" >/dev/null 2>&1 ); echo $?; }

# --- Invocation contract (no repo needed) ------------------------------------
# Reuse rc_in() rather than a raw `$(( cd ... ))` — the latter reads as an
# arithmetic-expansion opener (shellcheck SC1102) and errors under POSIX sh.
assert "--help exits 0" "0" "$(bash "$SCRIPT" --help >/dev/null 2>&1; echo $?)"
plain="$(mktemp -d)"; SANDBOXES+=("$plain")
assert "unknown option exits 1" "1" "$(rc_in "$plain" --bogus)"
assert "outside a git repo exits 1" "1" "$(rc_in "$plain")"

# --- Config / worktree preconditions -----------------------------------------
norc_repo="$(mktemp -d)"; SANDBOXES+=("$norc_repo")
git -C "$norc_repo" init -q
assert "rite-config.yml absent exits 1" "1" "$(rc_in "$norc_repo")"

disabled_repo="$(new_repo false)"; SANDBOXES+=("$disabled_repo")
assert "wiki disabled exits 2" "2" "$(rc_in "$disabled_repo")"
# Capture stdout to a variable first: run_in exits 2 here, and `set -o pipefail`
# would make `run_in | grep` report the pipeline as failed even on a grep match.
disabled_out="$(run_in "$disabled_repo")"
if printf '%s' "$disabled_out" | grep -q 'reason=wiki-disabled'; then
  pass "wiki disabled reports reason=wiki-disabled"
else
  fail "wiki-disabled reason line missing: $disabled_out"
fi

missing_wt_repo="$(new_repo true)"; SANDBOXES+=("$missing_wt_repo")
assert "worktree missing exits 1" "1" "$(rc_in "$missing_wt_repo")"

# --- No pending changes → no-op commit=0 -------------------------------------
nopending_repo="$(new_repo true)"; SANDBOXES+=("$nopending_repo")
setup_wiki_worktree "$nopending_repo"
assert "no pending changes exits 0" "0" "$(rc_in "$nopending_repo")"
nopending_out="$(run_in "$nopending_repo")"
if printf '%s' "$nopending_out" | grep -q 'committed=0; branch=wiki; reason=no-pending'; then
  pass "no pending reports committed=0; reason=no-pending"
else
  fail "no-pending status line missing: $nopending_out"
fi

# --- newline --message guard, isolated -----------------------------------
# The header-smuggling guard fires BEFORE the git/worktree checks. Run against a
# fully-built repo where a benign message reaches the no-pending exit 0, so the
# benign=0 / newline=1 differential pins the guard specifically — a bare non-git
# dir would give exit 1 on both (from the not-a-git-repo check) and not isolate it.
assert "benign --message reaches no-pending (exit 0)" "0" "$(rc_in "$nopending_repo" --message "safe message")"
assert "--message with newline is rejected by the guard (exit 1)" "1" \
  "$(rc_in "$nopending_repo" --message "$(printf 'a\nb')")"

# --- Dry-run: reports pending, performs no commit ----------------------------
dryrun_repo="$(new_repo true)"; SANDBOXES+=("$dryrun_repo")
setup_wiki_worktree "$dryrun_repo"
add_pending "$dryrun_repo"
wiki_before_dry="$(git -C "$dryrun_repo" rev-parse wiki)"
dry_out="$(run_in "$dryrun_repo" --dry-run)"
wiki_after_dry="$(git -C "$dryrun_repo" rev-parse wiki)"
assert "dry-run does not advance the wiki branch" "$wiki_before_dry" "$wiki_after_dry"
if printf '%s' "$dry_out" | grep -qE 'dry-run; branch=wiki'; then
  pass "dry-run reports the dry-run status line"
else
  fail "dry-run status line missing: $dry_out"
fi

# --- Happy path: commit + push to LOCAL bare origin (AC-4) --------------------
commit_repo="$(new_repo true)"; SANDBOXES+=("$commit_repo")
setup_wiki_worktree "$commit_repo"
add_pending "$commit_repo"
origin_before="$(git -C "$commit_repo" rev-parse origin/wiki)"
commit_out="$(run_in "$commit_repo")"
if printf '%s' "$commit_out" | grep -qE 'committed=1; branch=wiki;.*push=ok'; then
  pass "pending change is committed and pushed to the local bare origin (push=ok)"
else
  fail "expected committed=1 + push=ok; got: $commit_out"
fi
origin_after="$(git -C "$commit_repo" rev-parse origin/wiki)"
assert "local bare origin/wiki advanced (push landed, no network)" \
  "advanced" \
  "$([ "$origin_before" != "$origin_after" ] && echo advanced || echo unchanged)"
# The committed page is now tracked on the wiki branch.
if git -C "$commit_repo" ls-tree -r --name-only wiki | grep -q '.rite/wiki/pages/test.md'; then
  pass "committed page is tracked on the wiki branch"
else
  fail "committed page not found on wiki branch"
fi

print_summary "wiki-worktree-commit.sh"
