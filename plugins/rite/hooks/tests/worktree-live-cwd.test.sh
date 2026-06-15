#!/bin/bash
# Tests for worktree-live-cwd.sh — OS-ground-truth liveness probe (Issue #1544).
#
#   TC-1: missing <dir> argument                       → rc 2
#   TC-2: directory with NO process standing in it     → rc 1
#   TC-3: a process whose cwd IS the directory         → rc 0
#   TC-4: a process whose cwd is NESTED under the dir  → rc 0
#   TC-5: sibling-prefix dir (issue-1 vs issue-12)     → no false match (rc 1)
#   TC-6: after the holder exits, the dir is free again → rc 1
#
# These pin the contract the reap gate (pr-cycle-cleanup.sh Step 5) and the
# cleanup removal (cleanup.md Step 4-W) depend on: "don't delete a worktree a
# live process is standing in", independent of rite flow-state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PROBE="$SCRIPT_DIR/../scripts/worktree-live-cwd.sh"

cleanup_dirs=()
holders=()
cleanup() {
  local p d
  # `|| true`: a holder may already have exited (e.g. TC-6's short sleep), so kill
  # returns non-zero — without the guard, set -e would abort the EXIT trap.
  for p in "${holders[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
  return 0
}
trap cleanup EXIT

# Run the probe and echo its exit code (probe rc is the contract under test).
probe_rc() { bash "$PROBE" "$@" >/dev/null 2>&1; echo "$?"; }

echo "=== TC-1: missing argument → rc 2 ==="
assert "TC-1 no arg → rc 2" "2" "$(bash "$PROBE" >/dev/null 2>&1; echo $?)"

echo "=== TC-2: empty directory, no process inside → rc 1 ==="
D=$(mktemp -d); cleanup_dirs+=("$D")
assert "TC-2 free dir → rc 1" "1" "$(probe_rc "$D")"

echo "=== TC-3: a process holds cwd == dir → rc 0 ==="
( cd "$D" && sleep 30 ) & holders+=("$!")
sleep 0.3
assert "TC-3 held dir → rc 0" "0" "$(probe_rc "$D")"

echo "=== TC-4: a process holds cwd nested under dir → rc 0 ==="
D2=$(mktemp -d); cleanup_dirs+=("$D2")
mkdir -p "$D2/sub/deep"
( cd "$D2/sub/deep" && sleep 30 ) & holders+=("$!")
sleep 0.3
assert "TC-4 nested-held dir → rc 0" "0" "$(probe_rc "$D2")"

echo "=== TC-5: sibling-prefix dir must not false-match (issue-1 vs issue-12) ==="
D3=$(mktemp -d); cleanup_dirs+=("$D3")
mkdir -p "$D3/issue-1" "$D3/issue-12"
( cd "$D3/issue-12" && sleep 30 ) & holders+=("$!")
sleep 0.3
assert "TC-5 issue-1 not matched by issue-12 holder → rc 1" "1" "$(probe_rc "$D3/issue-1")"
assert "TC-5 issue-12 itself matched → rc 0" "0" "$(probe_rc "$D3/issue-12")"

echo "=== TC-6: after holder exits the dir is free again → rc 1 ==="
D4=$(mktemp -d); cleanup_dirs+=("$D4")
( cd "$D4" && sleep 1 ) & hp=$!
sleep 0.3
assert "TC-6 while held → rc 0" "0" "$(probe_rc "$D4")"
wait "$hp" 2>/dev/null || true
assert "TC-6 after holder exits → rc 1" "1" "$(probe_rc "$D4")"

if ! print_summary "$(basename "$0")" "worktree-live-cwd.sh の OS 接地 liveness 判定 (Issue #1544)"; then
  exit 1
fi
