#!/bin/bash
# Tests for pr-cycle-cleanup.sh Step 5 — session worktree lazy reap
# (Issue #1364 / S4, multi-session design §8).
#
#   AC-1: a worktree whose claim is LIVE is NOT reaped.
#   AC-2: a worktree whose claim is STALE and clean IS reaped, claim file deleted.
#   AC-3: a DIRTY worktree is NOT reaped (claim stale) — WARNING + manual hint.
#   AC-4: after reap the corresponding branch still exists.
#   AC-5: `.rite/wiki-worktree` and non-issue dirs are NOT matched (regression).
#
# Gate 0 — self-exclusion guard (Issue #1438). A long-lived session must never
# reap the worktree it is itself running in (the real incident: review Step 1.0.0
# deleted the in-flight worktree under a stale/free claim). TC-7..TC-11 invoke
# cleanup FROM INSIDE the candidate worktree (or via RITE_WORKTREE) and assert it
# survives even when gates 1-3 alone would reap it:
#   TC-7  → #1438 AC-1: cwd == self worktree → NOT reaped (would-be-reaped: stale+clean)
#   TC-8  → #1438 AC-2: the self-exclusion skip is logged to stderr (not silent)
#   TC-9  → #1438 AC-3: a coexisting OTHER stale orphan is still reaped (surgical)
#   TC-10 → #1438 AC-4: a dirty self worktree is also never reaped (TC-3 covers
#                       the dirty + non-self half — Gate 3 unchanged)
#   TC-11 → #1438 AC-1: RITE_WORKTREE env resolves self even when cwd is elsewhere
#                       (the lost-cwd robustness path; cleanup runs from main checkout)
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

# Run pr-cycle-cleanup from an arbitrary cwd ($1), capturing stderr to an
# explicit, stable path ($2). Used to simulate self-invocation from INSIDE a
# session worktree — the path the real incident took (#1438). RITE_WORKTREE is
# unset so these cases exercise the cwd-based Gate 0 resolution; TC-11 covers the
# env-based path separately. $2 is absolute so the redirect is unaffected by the cd.
run_pcc_from() { ( cd "$1" && env -u RITE_WORKTREE bash "$PCC" 2>"$2"; echo "rc=$?" ) ; }

echo "=== TC-7 (#1438 AC-1): cwd == self worktree → NOT reaped even when reapable ==="
R=$(make_repo 60); cleanup_dirs+=("$R")
# Make the holder (SID_A) stale so issue-60 would pass gates 1-3 (clean + stale).
# Only Gate 0 can save it now → non-vacuous (drop Gate 0 and every TC-7 assert flips).
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$(run_pcc_from "$R/.rite/worktrees/issue-60" "$R/pcc.err")
assert "TC-7 self worktree survives (cwd self-exclusion)" "1" "$( [ -d "$R/.rite/worktrees/issue-60" ] && echo 1 || echo 0 )"
assert "TC-7 claim file survives (not reaped)" "1" "$( [ -f "$R/.rite/state/issue-claims/issue-60.json" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=0"*) pass "TC-7 status reports session_worktrees=0" ;; *) fail "TC-7 status: $out" ;; esac

echo "=== TC-8 (#1438 AC-2): self-exclusion skip is logged to stderr (not silent) ==="
# Reuses R/pcc.err from TC-7's self-invocation.
assert_grep "TC-8 self-exclusion WARNING on stderr" "$R/pcc.err" "self-exclusion"

echo "=== TC-9 (#1438 AC-3): a coexisting OTHER orphan is still reaped (surgical) ==="
R=$(make_repo 61); cleanup_dirs+=("$R")
# A second session worktree (issue-62), also held by SID_A, becomes a reapable
# orphan once SID_A goes stale. Self-exclusion must skip ONLY the self worktree
# (issue-61), never the sibling — proving the guard is surgical, not "skip all".
( cd "$R" && $GIT worktree add -q -b "feat/issue-62" ".rite/worktrees/issue-62" >/dev/null 2>&1 )
RITE_STATE_ROOT="$R" bash "$IC" claim --issue 62 --session "$SID_A" --worktree "$R/.rite/worktrees/issue-62" >/dev/null 2>&1
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$(run_pcc_from "$R/.rite/worktrees/issue-61" "$R/pcc.err")
assert "TC-9 self worktree (issue-61) survives" "1" "$( [ -d "$R/.rite/worktrees/issue-61" ] && echo 1 || echo 0 )"
assert "TC-9 sibling orphan (issue-62) reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-62" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "TC-9 status reports session_worktrees=1" ;; *) fail "TC-9 status: $out" ;; esac

echo "=== TC-10 (#1438 AC-4): a dirty self worktree is also never reaped ==="
# AC-4 = dirty protection unchanged. TC-3 covers dirty + NON-self (Gate 3 path);
# this is the dirty + self half of T-4's "self-exclusion 判定の有無に関わらず".
# Gate 0 sits before Gate 3, so a dirty SELF worktree is skipped via self-exclusion
# (not the dirty gate). Asserting the self-exclusion WARNING (rather than just
# survival) makes TC-10 non-vacuous for Gate 0: drop Gate 0 and the dirty self
# falls through to the Gate 3 dirty WARNING instead, flipping this assert.
R=$(make_repo 63); cleanup_dirs+=("$R")
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
echo "uncommitted" > "$R/.rite/worktrees/issue-63/dirty.txt"   # untracked → dirty porcelain
out=$(run_pcc_from "$R/.rite/worktrees/issue-63" "$R/pcc.err")
assert "TC-10 dirty self worktree survives" "1" "$( [ -d "$R/.rite/worktrees/issue-63" ] && echo 1 || echo 0 )"
assert_grep "TC-10 dirty self skipped via Gate 0 (not Gate 3)" "$R/pcc.err" "self-exclusion"
case "$out" in *"session_worktrees=0"*) pass "TC-10 status reports session_worktrees=0" ;; *) fail "TC-10 status: $out" ;; esac

echo "=== TC-11 (#1438 AC-1): RITE_WORKTREE env resolves self even when cwd is elsewhere ==="
# Gate 0 has two inputs: cwd (TC-7/9/10) and RITE_WORKTREE env. Here cleanup runs
# from the MAIN checkout (cwd would NOT match the candidate), but RITE_WORKTREE
# points at the worktree → Gate 0 still protects it (the lost-cwd robustness path).
R=$(make_repo 64); cleanup_dirs+=("$R")
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$( cd "$R" && RITE_WORKTREE="$R/.rite/worktrees/issue-64" bash "$PCC" 2>"$R/pcc.err"; echo "rc=$?" )
assert "TC-11 RITE_WORKTREE-named worktree survives" "1" "$( [ -d "$R/.rite/worktrees/issue-64" ] && echo 1 || echo 0 )"
assert_grep "TC-11 self-exclusion WARNING on stderr" "$R/pcc.err" "self-exclusion"
case "$out" in *"session_worktrees=0"*) pass "TC-11 status reports session_worktrees=0" ;; *) fail "TC-11 status: $out" ;; esac

print_summary "$(basename "$0")" \
  "Drift hint: pr-cycle-cleanup.sh Step 5 §8 — Gate 0 self-exclusion (cwd/RITE_WORKTREE == self → never reap, #1438) + 3 gates (strict ^issue-[0-9]+$ / claim not-live / clean); branch preserved; wiki-worktree excluded; session-start best-effort wiring."
