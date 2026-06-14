#!/bin/bash
# Tests for issue-claim.sh (multi-session design §7).
#
# Covers:
#   AC-1: concurrent claim → exactly one process succeeds (noclobber atomicity)
#   AC-2: own | other | stale classification (live / active=false / >2h)
#   AC-3: release removes only the OWN claim; another session's is untouched
#   AC-4: release on an absent claim is idempotent (success)
#   plus: free check, stale-steal, corrupt-claim → stale, live-other refusal (rc 10)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

IC="$SCRIPT_DIR/../issue-claim.sh"
FS="$SCRIPT_DIR/../flow-state.sh"

SID_A="aaaaaaaa-1111-2222-3333-444444444444"
SID_B="bbbbbbbb-5555-6666-7777-888888888888"

cleanup_dirs=()
cleanup() { local d; for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

ROOT=$(make_sandbox --branch develop)
cleanup_dirs+=("$ROOT")
export RITE_STATE_ROOT="$ROOT"

# Helper: set an active flow-state for a session (makes its claim "live").
mk_active() { bash "$FS" set --session "$1" --phase implement --issue "$2" --branch x --next n >/dev/null 2>&1; }
claim()   { bash "$IC" claim   --session "$1" --issue "$2" ${3:+--worktree "$3"} 2>/dev/null; }
check()   { bash "$IC" check   --session "$1" --issue "$2" 2>/dev/null; }
release() { bash "$IC" release --session "$1" --issue "$2" 2>/dev/null; }

# === AC-2 / free / own / other / stale ===
echo "=== TC-1: check on free issue → free ==="
assert "TC-1 free" "free" "$(check "$SID_A" 700)"

echo "=== TC-2: claim → claimed; check → own ==="
mk_active "$SID_A" 700
assert "TC-2 claimed" "claimed" "$(claim "$SID_A" 700)"
assert "TC-2 own" "own" "$(check "$SID_A" 700)"

echo "=== TC-3 (AC-2): other session sees live claim as 'other' ==="
assert "TC-3 other" "other" "$(check "$SID_B" 700)"

echo "=== TC-4 (AC-5): claim by other live session refused (rc 10, prints 'other') ==="
rc=0; out=$(bash "$IC" claim --session "$SID_B" --issue 700 2>/dev/null) || rc=$?
assert "TC-4 prints other" "other" "$out"
assert "TC-4 rc 10" "10" "$rc"

echo "=== TC-5 (AC-3): other session's release does NOT touch the claim ==="
assert "TC-5 release skipped" "skipped" "$(release "$SID_B" 700)"
assert "TC-5 holder still A" "$SID_A" "$(jq -r .session_id "$ROOT/.rite/state/issue-claims/issue-700.json")"

echo "=== TC-6 (AC-2): active=false holder → stale; stale-steal succeeds ==="
bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
assert "TC-6 stale (inactive)" "stale" "$(check "$SID_B" 700)"
assert "TC-6 steal → claimed" "claimed" "$(claim "$SID_B" 700)"
assert "TC-6 holder now B" "$SID_B" "$(jq -r .session_id "$ROOT/.rite/state/issue-claims/issue-700.json")"

echo "=== TC-7 (AC-2): holder updated_at > 2h → stale ==="
mk_active "$SID_A" 701
claim "$SID_A" 701 >/dev/null
PAST=$(date -u -d '3 hours ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-3H +"%Y-%m-%dT%H:%M:%SZ")
tmp=$(mktemp); jq --arg t "$PAST" '.updated_at=$t' "$ROOT/.rite/sessions/$SID_A.flow-state" > "$tmp" && mv "$tmp" "$ROOT/.rite/sessions/$SID_A.flow-state"
assert "TC-7 stale (2h aged)" "stale" "$(check "$SID_B" 701)"

echo "=== TC-8 (AC-4): release on absent claim is idempotent ==="
assert "TC-8 release absent → released" "released" "$(release "$SID_A" 9999)"

echo "=== TC-9: own-claim refresh stores worktree path; release removes it ==="
mk_active "$SID_A" 702
claim "$SID_A" 702 "/abs/wt/issue-702" >/dev/null
assert "TC-9 worktree recorded" "/abs/wt/issue-702" "$(jq -r .worktree "$ROOT/.rite/state/issue-claims/issue-702.json")"
assert "TC-9 release own" "released" "$(release "$SID_A" 702)"
assert "TC-9 check free after release" "free" "$(check "$SID_A" 702)"

echo "=== TC-10: corrupt claim file → stale (reclaimable) ==="
mkdir -p "$ROOT/.rite/state/issue-claims"
printf 'not-json{' > "$ROOT/.rite/state/issue-claims/issue-703.json"
assert "TC-10 corrupt → stale" "stale" "$(check "$SID_A" 703)"

echo "=== TC-11 (AC-1): 5 concurrent claims → exactly one 'claimed' ==="
for i in 1 2 3 4 5; do mk_active "0000000$i-1111-2222-3333-444444444444" 900; done
rm -f "$ROOT"/claimout.* 2>/dev/null || true
for i in 1 2 3 4 5; do
  ( bash "$IC" claim --session "0000000$i-1111-2222-3333-444444444444" --issue 900 > "$ROOT/claimout.$i" 2>/dev/null ) &
done
wait
_claimed=0
for i in 1 2 3 4 5; do [ "$(cat "$ROOT/claimout.$i" 2>/dev/null)" = "claimed" ] && _claimed=$((_claimed+1)); done
assert "TC-11 exactly one claimed" "1" "$_claimed"

echo "=== TC-12: invalid --issue rejected (rc 1) ==="
rc=0; bash "$IC" claim --session "$SID_A" --issue abc >/dev/null 2>&1 || rc=$?; assert "TC-12 non-numeric rc 1" "1" "$rc"
rc=0; bash "$IC" check --session "$SID_A" --issue 0 >/dev/null 2>&1 || rc=$?; assert "TC-12 zero rc 1" "1" "$rc"

echo "=== TC-13 (Issue #1530): env-first resolution in _resolve_current_session_id (no --session path) ==="
# Regression guard for the env-first precedence flip (review F-01). All TCs above pass --session,
# so the env/file branch was never exercised — issue-claim.sh's env-first reorder was a dead guard
# (mutation: reverting it to file-first kept every TC green). This pins env-first directly.
#
# Part 1: env outranks a differing .rite-session-id. A no-override claim must key its holder to env
# (SID_A), not the stale shared file (SID_B). Reverting issue-claim.sh to file-first fails this assert.
rm -f "$ROOT/.rite/state/issue-claims/issue-710.json" 2>/dev/null || true
printf '%s' "$SID_B" > "$ROOT/.rite-session-id"   # shared file says SID_B (stale)
mk_active "$SID_A" 710                              # env session SID_A is the live one
env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$SID_A" bash "$IC" claim --issue 710 >/dev/null 2>&1
assert "TC-13 no-override claim holder is env sid (SID_A), not stale file sid (SID_B)" \
  "$SID_A" "$(jq -r .session_id "$ROOT/.rite/state/issue-claims/issue-710.json")"
# Part 2: env-absent fallback resolves the FILE sid (SID_B) — proven by holder==SID_B AND check==own
# (resolver returned SID_B == holder), not merely a non-holder classification that empty would also give.
rm -f "$ROOT/.rite/state/issue-claims/issue-711.json" 2>/dev/null || true
mk_active "$SID_B" 711                              # holder SID_B, file also SID_B, env unset below
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$IC" claim --issue 711 >/dev/null 2>&1
assert "TC-13 env-absent claim holder resolved via file sid (SID_B)" \
  "$SID_B" "$(jq -r .session_id "$ROOT/.rite/state/issue-claims/issue-711.json")"
assert "TC-13 env-absent check own (resolver returned file sid SID_B == holder)" \
  "own" "$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$IC" check --issue 711)"

print_summary "$(basename "$0")" \
  "Drift hint: issue-claim.sh §7 — claim/release/check; liveness reuses session-ownership.sh 2h threshold + parse_iso8601_to_epoch; noclobber + flock atomicity; _resolve_current_session_id env-first (Issue #1530)."
