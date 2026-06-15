#!/bin/bash
# Tests for pr-cycle-cleanup.sh Step 5 — session worktree lazy reap
# (S4, multi-session design §8).
#
#   AC-1: a worktree whose claim is LIVE is NOT reaped.
#   AC-2: a worktree whose claim is STALE and clean IS reaped, claim file deleted.
#   AC-3: a DIRTY worktree is NOT reaped (claim stale) — WARNING + manual hint.
#   AC-4: after reap the corresponding branch still exists.
#   AC-5: `.rite/wiki-worktree` and non-issue dirs are NOT matched (regression).
#
# Gate 0 — self-exclusion guard. A long-lived session must never
# reap the worktree it is itself running in (the real incident: review Step 1.0.0
# deleted the in-flight worktree under a stale/free claim). TC-7..TC-11 invoke
# cleanup FROM INSIDE the candidate worktree (or via RITE_WORKTREE) and assert it
# survives even when gates 1-3 alone would reap it:
#   TC-7  → AC-1: cwd == self worktree → NOT reaped (would-be-reaped: stale+clean)
#   TC-8  → AC-2: the self-exclusion skip is logged to stderr (not silent)
#   TC-9  → AC-3: a coexisting OTHER stale orphan is still reaped (surgical)
#   TC-10 → AC-4: a dirty self worktree is also never reaped (TC-3 covers
#                       the dirty + non-self half — Gate 3 unchanged)
#   TC-11 → AC-1: RITE_WORKTREE env resolves self even when cwd is elsewhere
#                       (the lost-cwd robustness path; cleanup runs from main checkout)
set -euo pipefail

# Clean session-id env (Issue #1530). The reaper resolves its session via
# `issue-claim.sh check`, which is now env-first; this test makes the reaper act as
# SID_B by writing `.rite-session-id`=SID_B, so the dogfooding session's ambient
# CLAUDE_CODE_SESSION_ID must not leak in (it would make the reaper resolve a foreign
# sid instead of SID_B). run-tests.sh unsets the same vars for suite runs; this keeps
# the standalone run deterministic too.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PCC="$SCRIPT_DIR/../scripts/pr-cycle-cleanup.sh"
FS="$SCRIPT_DIR/../flow-state.sh"
IC="$SCRIPT_DIR/../issue-claim.sh"
GIT="git -c user.email=t@test.local -c user.name=test -c commit.gpgsign=false"

cleanup_dirs=()
holder_pids=()   # background processes that hold cwd inside a worktree (Issue #1544 TCs)
cleanup() {
  local p d
  # `|| true`: a holder killed inline earlier is already dead here, so kill returns
  # non-zero — without the guard, set -e would abort the EXIT trap and the whole
  # test would exit non-zero despite all assertions passing.
  for p in "${holder_pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
  return 0
}
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
# session worktree — the path the real incident took. RITE_WORKTREE is
# unset so these cases exercise the cwd-based Gate 0 resolution; TC-11 covers the
# env-based path separately. $2 is absolute so the redirect is unaffected by the cd.
run_pcc_from() { ( cd "$1" && env -u RITE_WORKTREE bash "$PCC" 2>"$2"; echo "rc=$?" ) ; }

echo "=== TC-7 (AC-1): cwd == self worktree → NOT reaped even when reapable ==="
R=$(make_repo 60); cleanup_dirs+=("$R")
# Make the holder (SID_A) stale so issue-60 would pass gates 1-3 (clean + stale).
# Only Gate 0 can save it now → non-vacuous (drop Gate 0 and every TC-7 assert flips).
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$(run_pcc_from "$R/.rite/worktrees/issue-60" "$R/pcc.err")
assert "TC-7 self worktree survives (cwd self-exclusion)" "1" "$( [ -d "$R/.rite/worktrees/issue-60" ] && echo 1 || echo 0 )"
assert "TC-7 claim file survives (not reaped)" "1" "$( [ -f "$R/.rite/state/issue-claims/issue-60.json" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=0"*) pass "TC-7 status reports session_worktrees=0" ;; *) fail "TC-7 status: $out" ;; esac

echo "=== TC-8 (AC-2): self-exclusion skip is logged to stderr (not silent) ==="
# Reuses R/pcc.err from TC-7's self-invocation.
assert_grep "TC-8 self-exclusion WARNING on stderr" "$R/pcc.err" "self-exclusion"

echo "=== TC-9 (AC-3): a coexisting OTHER orphan is still reaped (surgical) ==="
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

echo "=== TC-10 (AC-4): a dirty self worktree is also never reaped ==="
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

echo "=== TC-11 (AC-1): RITE_WORKTREE env resolves self even when cwd is elsewhere ==="
# Gate 0 has two inputs: cwd (TC-7/9/10) and RITE_WORKTREE env. Here cleanup runs
# from the MAIN checkout (cwd would NOT match the candidate), but RITE_WORKTREE
# points at the worktree → Gate 0 still protects it (the lost-cwd robustness path).
R=$(make_repo 64); cleanup_dirs+=("$R")
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$( cd "$R" && RITE_WORKTREE="$R/.rite/worktrees/issue-64" bash "$PCC" 2>"$R/pcc.err"; echo "rc=$?" )
assert "TC-11 RITE_WORKTREE-named worktree survives" "1" "$( [ -d "$R/.rite/worktrees/issue-64" ] && echo 1 || echo 0 )"
assert_grep "TC-11 self-exclusion WARNING on stderr" "$R/pcc.err" "self-exclusion"
case "$out" in *"session_worktrees=0"*) pass "TC-11 status reports session_worktrees=0" ;; *) fail "TC-11 status: $out" ;; esac

# ===========================================================================
# Issue #1524 — cross-session liveness guard (4th protection layer) + reap-time
# flow-state worktree null-ing. The guard protects a worktree that ANOTHER live
# session (flow-state active=true) records as its `worktree`, EVEN when that
# session's claim has gone stale — flow-state liveness > claim liveness (Gate 2).
# SID_C = a third (distinct) holder session used by the prefix-collision test.
# ===========================================================================
SID_C="cccccccc-9999-aaaa-bbbb-cccccccccccc"

# Helper: age a flow-state's updated_at so the holder's CLAIM goes stale while
# keeping active=true + worktree recorded — the exact incident shape (live session,
# expired claim heartbeat). Without aging, the claim stays "other" (live) and Gate 2
# alone would protect the worktree, making the new guard's contribution vacuous.
age_flow_state() {
  local sf="$1" tmp
  tmp=$(mktemp) || return 1
  jq '.updated_at = "2020-01-01T00:00:00Z"' "$sf" > "$tmp" && mv "$tmp" "$sf"
}

echo "=== T-01 (AC-1): live-session flow-state worktree ref → NOT reaped even when claim stale ==="
R=$(make_repo 70); cleanup_dirs+=("$R")
# Record the worktree in SID_A's flow-state (the live-session reference), then age
# updated_at so the claim is "stale" (Gate 2 would reap) while active=true (guard protects).
RITE_STATE_ROOT="$R" bash "$FS" set --session "$SID_A" --phase implement --issue 70 \
  --branch "feat/issue-70" --next n --worktree "$R/.rite/worktrees/issue-70" >/dev/null 2>&1
age_flow_state "$R/.rite/sessions/${SID_A}.flow-state"
claim_now=$(RITE_STATE_ROOT="$R" bash "$IC" check --issue 70 --session "$SID_B" 2>/dev/null)
out=$(run_pcc "$R")
assert "T-01 claim is stale (guard non-vacuous: Gate 2 alone would reap)" "stale" "$claim_now"
assert "T-01 live-referenced worktree survives (cross-session liveness)" "1" "$( [ -d "$R/.rite/worktrees/issue-70" ] && echo 1 || echo 0 )"
assert_grep "T-01 cross-session liveness WARNING on stderr" "$R/pcc.err" "cross-session liveness"
case "$out" in *"session_worktrees=0"*) pass "T-01 status reports session_worktrees=0" ;; *) fail "T-01 status: $out" ;; esac

echo "=== T-03 (AC-3): inactive flow-state worktree ref does NOT over-protect → reaped + owner ref nulled ==="
R=$(make_repo 71); cleanup_dirs+=("$R")
# SID_A records the worktree but is then deactivated (active=false) → NOT a live ref.
RITE_STATE_ROOT="$R" bash "$FS" set --session "$SID_A" --phase implement --issue 71 \
  --branch "feat/issue-71" --next n --worktree "$R/.rite/worktrees/issue-71" >/dev/null 2>&1
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$(run_pcc "$R")
assert "T-03 orphan worktree reaped (inactive ref not over-protected)" "0" "$( [ -d "$R/.rite/worktrees/issue-71" ] && echo 1 || echo 0 )"
assert "T-03 claim file deleted" "0" "$( [ -f "$R/.rite/state/issue-claims/issue-71.json" ] && echo 1 || echo 0 )"
assert "T-03 owner flow-state worktree nulled after reap" "false" "$(jq -r 'has("worktree")' "$R/.rite/sessions/${SID_A}.flow-state" 2>/dev/null)"
case "$out" in *"session_worktrees=1"*) pass "T-03 status reports session_worktrees=1" ;; *) fail "T-03 status: $out" ;; esac

echo "=== T-04 (AC-4): flow-state parse failure → conservative skip + WARNING ==="
R=$(make_repo 72); cleanup_dirs+=("$R")
# Stale the claim so the worktree WOULD be reaped (non-vacuous), then drop a corrupt
# flow-state so the guard's jq parse fails → conservative skip. Corrupt-file (vs
# chmod) keeps the test uid-independent (root would bypass an unreadable dir).
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
printf '{ this is not valid json' > "$R/.rite/sessions/corrupt-sess.flow-state"
out=$(run_pcc "$R")
assert "T-04 worktree survives (conservative skip on parse failure)" "1" "$( [ -d "$R/.rite/worktrees/issue-72" ] && echo 1 || echo 0 )"
assert_grep "T-04 conservative-skip WARNING on stderr" "$R/pcc.err" "保護判定に必要な flow-state"
case "$out" in *"session_worktrees=0"*) pass "T-04 status reports session_worktrees=0" ;; *) fail "T-04 status: $out" ;; esac

echo "=== T-06 (AC-6): new guard + strict regex — issue-1 (live-ref) protected, issue-12 (orphan) reaped, no prefix bleed ==="
R=$(make_repo 1); cleanup_dirs+=("$R")
# issue-1: live flow-state ref (active + worktree) with a stale claim → guard protects.
RITE_STATE_ROOT="$R" bash "$FS" set --session "$SID_A" --phase implement --issue 1 \
  --branch "feat/issue-1" --next n --worktree "$R/.rite/worktrees/issue-1" >/dev/null 2>&1
age_flow_state "$R/.rite/sessions/${SID_A}.flow-state"
# issue-12: a sibling orphan held by a DIFFERENT inactive session → reapable. Proves the
# guard's path matching + Gate 1 strict regex do not let issue-1 protect issue-12.
( cd "$R" && $GIT worktree add -q -b "feat/issue-12" ".rite/worktrees/issue-12" >/dev/null 2>&1 )
RITE_STATE_ROOT="$R" bash "$IC" claim --issue 12 --session "$SID_C" --worktree "$R/.rite/worktrees/issue-12" >/dev/null 2>&1
RITE_STATE_ROOT="$R" bash "$FS" set --session "$SID_C" --phase implement --issue 12 --branch "feat/issue-12" --next n >/dev/null 2>&1
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_C" --next done >/dev/null 2>&1
out=$(run_pcc "$R")
assert "T-06 issue-1 (live-ref) survives" "1" "$( [ -d "$R/.rite/worktrees/issue-1" ] && echo 1 || echo 0 )"
assert "T-06 issue-12 (orphan) reaped (no prefix bleed from issue-1)" "0" "$( [ -d "$R/.rite/worktrees/issue-12" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "T-06 status reports session_worktrees=1 (only issue-12)" ;; *) fail "T-06 status: $out" ;; esac

# ===========================================================================
# Issue #1544 — OS-level live-cwd guard (regression of #1524). The cross-session
# liveness guard only protects worktrees a session records as its `active`
# `worktree`; it misses the dangling cases where the owning session's harness cwd
# is still IN the tree but its flow-state has drifted (active=false, no `worktree`
# field, stale session-id). The live-cwd guard (worktree-live-cwd.sh) closes that
# gap by reading the OS's own per-process cwd, independent of flow-state.
# ===========================================================================
echo "=== T-07 (Issue #1544): a live process standing in a clean+stale worktree → NOT reaped (live-cwd guard) ==="
R=$(make_repo 80); cleanup_dirs+=("$R")
# Fully drift flow-state: deactivate the holder (active=false) and leave NO
# `worktree` field (make_repo's flow-state set records none) → neither the
# cross-session liveness guard nor the claim gate protects issue-80. Only the
# OS-level live-cwd guard can save it (non-vacuous: drop the guard and T-07 flips).
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
# A live process stands in the worktree — the exact "harness cwd still in the
# tree" shape that makes /clear fail when the tree is reaped out from under it.
( cd "$R/.rite/worktrees/issue-80" && sleep 30 ) & _h80=$!
holder_pids+=("$_h80")
sleep 0.3
out=$(run_pcc "$R")
assert "T-07 worktree with live cwd survives (live-cwd guard)" "1" "$( [ -d "$R/.rite/worktrees/issue-80" ] && echo 1 || echo 0 )"
assert "T-07 claim file survives (not reaped)" "1" "$( [ -f "$R/.rite/state/issue-claims/issue-80.json" ] && echo 1 || echo 0 )"
assert_grep "T-07 live-cwd guard WARNING on stderr" "$R/pcc.err" "live-cwd guard"
case "$out" in *"session_worktrees=0"*) pass "T-07 status reports session_worktrees=0" ;; *) fail "T-07 status: $out" ;; esac
kill "$_h80" 2>/dev/null; wait "$_h80" 2>/dev/null || true

echo "=== T-08 (Issue #1544 non-regression): same clean+stale worktree with NO live cwd → reaped ==="
R=$(make_repo 81); cleanup_dirs+=("$R")
# Identical drift to T-07 but with nobody standing in the tree → the live-cwd
# guard must NOT over-protect: a genuine orphan is still reaped.
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$(run_pcc "$R")
assert "T-08 free clean+stale worktree reaped (no over-protection)" "0" "$( [ -d "$R/.rite/worktrees/issue-81" ] && echo 1 || echo 0 )"
assert "T-08 claim file deleted" "0" "$( [ -f "$R/.rite/state/issue-claims/issue-81.json" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "T-08 status reports session_worktrees=1" ;; *) fail "T-08 status: $out" ;; esac

print_summary "$(basename "$0")" \
  "Drift hint: pr-cycle-cleanup.sh Step 5 §8 — Gate 0 self-exclusion (cwd/RITE_WORKTREE == self → never reap) + cross-session liveness guard (Issue #1524: another live session's flow-state worktree ref → never reap; reap → null owner ref) + OS-level live-cwd guard (Issue #1544: any live process standing in the tree → never reap, via worktree-live-cwd.sh) + 3 gates (strict ^issue-[0-9]+$ / claim not-live / clean); branch preserved; wiki-worktree excluded; session-start best-effort wiring."
