#!/bin/bash
# Tests for pr-cycle-cleanup.sh Step 5 — session worktree lazy reap
# (Issue #1364 / S4, multi-session design §8).
#
#   AC-1: a worktree whose claim is LIVE is NOT reaped.
#   AC-2: a worktree whose claim is STALE and clean IS reaped, claim file deleted.
#   AC-3: a DIRTY worktree is NOT reaped (claim stale) — WARNING + manual hint.
#   AC-4: after reap the corresponding branch still exists.
#   AC-5: `.rite/wiki-worktree` and non-issue dirs are NOT matched (regression).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PCC="$SCRIPT_DIR/../scripts/pr-cycle-cleanup.sh"
FS="$SCRIPT_DIR/../flow-state.sh"
IC="$SCRIPT_DIR/../issue-claim.sh"
GIT="git -c user.email=t@test.local -c user.name=test -c commit.gpgsign=false"

cleanup_dirs=()
cleanup() { local d; for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

# SID_A = the "working" session that holds the claim; SID_B = the (different)
# session that triggers the reap (a new session-start / another session's
# cleanup). session↔worktree is not 1:1 so the reaping session is never the
# holder in practice.
SID_A="aaaaaaaa-1111-2222-3333-444444444444"
SID_B="bbbbbbbb-5555-6666-7777-888888888888"

# Build a main checkout with multi_session config + a session worktree for issue N.
# Echoes the main repo path. The holder session ($SID_A) gets an active flow-state
# and the claim; `.rite-session-id` is SID_B (the reaping session).
make_repo() {
  local n="$1" root
  root=$(make_sandbox --branch develop)
  printf 'multi_session:\n  enabled: true\n  worktree_base: ".rite/worktrees"\n' > "$root/rite-config.yml"
  printf '%s' "$SID_B" > "$root/.rite-session-id"
  ( cd "$root" && $GIT worktree add -q -b "feat/issue-$n" ".rite/worktrees/issue-$n" >/dev/null 2>&1 )
  RITE_STATE_ROOT="$root" bash "$FS" set --session "$SID_A" --phase implement --issue "$n" --branch "feat/issue-$n" --next n >/dev/null 2>&1
  RITE_STATE_ROOT="$root" bash "$IC" claim --issue "$n" --session "$SID_A" --worktree "$root/.rite/worktrees/issue-$n" >/dev/null 2>&1
  printf '%s' "$root"
}

run_pcc() { ( cd "$1" && bash "$PCC" 2>"$1/pcc.err"; echo "rc=$?" ) ; }

echo "=== TC-1 (AC-1): live claim → worktree NOT reaped ==="
R=$(make_repo 50); cleanup_dirs+=("$R")
# Holder SID_A is active → from the reaping session (SID_B) the claim is "other" (live).
run_pcc "$R" >/dev/null
assert "TC-1 live worktree survives" "1" "$( [ -d "$R/.rite/worktrees/issue-50" ] && echo 1 || echo 0 )"
assert "TC-1 claim file survives" "1" "$( [ -f "$R/.rite/state/issue-claims/issue-50.json" ] && echo 1 || echo 0 )"

echo "=== TC-2 (AC-2): stale claim + clean → reaped, claim deleted ==="
R=$(make_repo 51); cleanup_dirs+=("$R")
# make holder (SID_A) stale (inactive) → from SID_B the claim is "stale"
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$(run_pcc "$R")
assert "TC-2 stale worktree reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-51" ] && echo 1 || echo 0 )"
assert "TC-2 claim file deleted" "0" "$( [ -f "$R/.rite/state/issue-claims/issue-51.json" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "TC-2 status reports session_worktrees=1" ;; *) fail "TC-2 status: $out" ;; esac

echo "=== TC-4 (AC-4): branch preserved after reap ==="
assert "TC-4 branch feat/issue-51 still exists" "0" "$( cd "$R" && $GIT rev-parse --verify feat/issue-51 >/dev/null 2>&1; echo $? )"

echo "=== TC-3 (AC-3): dirty worktree (stale claim) → NOT reaped + WARNING ==="
R=$(make_repo 52); cleanup_dirs+=("$R")
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
echo "uncommitted" > "$R/.rite/worktrees/issue-52/dirty.txt"   # untracked → dirty porcelain
run_pcc "$R" >/dev/null
assert "TC-3 dirty worktree survives" "1" "$( [ -d "$R/.rite/worktrees/issue-52" ] && echo 1 || echo 0 )"
assert_grep "TC-3 WARNING emitted for dirty" "$R/pcc.err" "未コミット変更があるため auto-reap をスキップ"

echo "=== TC-5 (AC-5): .rite/wiki-worktree + non-issue dirs NOT matched ==="
R=$(make_repo 53); cleanup_dirs+=("$R")
# A wiki-worktree-shaped registered worktree must be excluded by the strict regex.
( cd "$R" && $GIT worktree add -q -b wiki ".rite/wiki-worktree" >/dev/null 2>&1 )
# holder SID_A made stale so issue-53 WOULD be reaped (proves the loop runs)
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
run_pcc "$R" >/dev/null
assert "TC-5 issue-53 reaped (loop active)" "0" "$( [ -d "$R/.rite/worktrees/issue-53" ] && echo 1 || echo 0 )"
assert "TC-5 .rite/wiki-worktree untouched" "1" "$( [ -d "$R/.rite/wiki-worktree" ] && echo 1 || echo 0 )"

echo "=== TC-6: session-start.sh best-effort wiring reaps a stale worktree ==="
R=$(make_repo 54); cleanup_dirs+=("$R")
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
SS="$SCRIPT_DIR/../session-start.sh"
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$SID_B" "$R" \
  | bash "$SS" >/dev/null 2>&1 || true
assert "TC-6 session-start reaped stale worktree" "0" "$( [ -d "$R/.rite/worktrees/issue-54" ] && echo 1 || echo 0 )"

print_summary "$(basename "$0")" \
  "Drift hint: pr-cycle-cleanup.sh Step 5 §8 — 3 gates (strict ^issue-[0-9]+$ / claim not-live / clean); branch preserved; wiki-worktree excluded; session-start best-effort wiring."
