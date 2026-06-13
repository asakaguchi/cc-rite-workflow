#!/bin/bash
# Tests for wiki-ingest-lock.sh (multi-session design §9).
#
# Verifies the ingest session lock used to serialize the LLM Write/Edit phase
# across sessions:
#   AC-3: a second session whose holder is LIVE is told concurrent_ingest (rc 11)
#   stale (holder inactive / >2h) → reclaimable
#   release removes only the OWN lock; idempotent on absent lock (AC-4 parity)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

WIL="$SCRIPT_DIR/../scripts/wiki-ingest-lock.sh"
FS="$SCRIPT_DIR/../flow-state.sh"
SID_A="aaaaaaaa-1111-2222-3333-444444444444"
SID_B="bbbbbbbb-5555-6666-7777-888888888888"

cleanup_dirs=()
cleanup() { local d; for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

ROOT=$(make_sandbox --branch develop)
cleanup_dirs+=("$ROOT")
export RITE_STATE_ROOT="$ROOT"
LOCKDIR="$ROOT/.rite/state/wiki-ingest-session.lockdir"

mk_active() { bash "$FS" set --session "$1" --phase ingest --issue 1 --branch x --next n >/dev/null 2>&1; }

echo "=== TC-1: free → acquire → own ==="
assert "TC-1 free" "free" "$(bash "$WIL" check --session "$SID_A")"
mk_active "$SID_A"
assert "TC-1 acquired" "acquired" "$(bash "$WIL" acquire --session "$SID_A")"
assert "TC-1 own" "own" "$(bash "$WIL" check --session "$SID_A")"
assert "TC-1 holder recorded" "$SID_A" "$(cat "$LOCKDIR/session_id")"

echo "=== TC-2 (AC-3): live other session → concurrent_ingest (rc 11) ==="
assert "TC-2 check held" "held" "$(bash "$WIL" check --session "$SID_B")"
rc=0; out=$(bash "$WIL" acquire --session "$SID_B" 2>/dev/null) || rc=$?
assert "TC-2 concurrent_ingest" "concurrent_ingest" "$out"
assert "TC-2 rc 11" "11" "$rc"

echo "=== TC-3: own re-acquire is idempotent ==="
assert "TC-3 re-acquire own" "acquired" "$(bash "$WIL" acquire --session "$SID_A")"

echo "=== TC-4: stale holder (inactive) → reclaimable ==="
bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
assert "TC-4 stale" "stale" "$(bash "$WIL" check --session "$SID_B")"
assert "TC-4 reclaim" "acquired_stale_reclaimed" "$(bash "$WIL" acquire --session "$SID_B")"
assert "TC-4 holder now B" "$SID_B" "$(cat "$LOCKDIR/session_id")"

echo "=== TC-5: release only own; other's lock untouched ==="
assert "TC-5 A release skipped (B holds)" "skipped" "$(bash "$WIL" release --session "$SID_A")"
assert "TC-5 still held by B" "$SID_B" "$(cat "$LOCKDIR/session_id")"
assert "TC-5 B release" "released" "$(bash "$WIL" release --session "$SID_B")"
assert "TC-5 free after release" "free" "$(bash "$WIL" check --session "$SID_A")"

echo "=== TC-6: release on absent lock is idempotent ==="
assert "TC-6 idempotent release" "released" "$(bash "$WIL" release --session "$SID_A")"

echo "=== TC-7: holder updated_at > 2h → stale ==="
mk_active "$SID_A"
bash "$WIL" acquire --session "$SID_A" >/dev/null
PAST=$(date -u -d '3 hours ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-3H +"%Y-%m-%dT%H:%M:%SZ")
tmp=$(mktemp); jq --arg t "$PAST" '.updated_at=$t' "$ROOT/.rite/sessions/$SID_A.flow-state" > "$tmp" && mv "$tmp" "$ROOT/.rite/sessions/$SID_A.flow-state"
assert "TC-7 stale (2h aged)" "stale" "$(bash "$WIL" check --session "$SID_B")"

print_summary "$(basename "$0")" \
  "Drift hint: wiki-ingest-lock.sh §9 — mkdir lock with session-flow-state liveness (2h), reclaim stale, concurrent_ingest rc 11."
