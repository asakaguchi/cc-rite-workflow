#!/bin/bash
# Tests for hooks/scripts/post-review-state-verify.sh worktree drift axis (#1944)
#
# post-review-state-verify.sh compares an ORIG_WTH snapshot (taken by
# pr-review SKILL.md ステップ 4.0.A) against a current worktree hash computed
# at verify time. Both sides now route through lib/git-status-filtered.sh
# instead of raw `git status --porcelain` so that sandbox write-block ghost
# mounts (#1936 — untracked character-device entries a bwrap sandbox overlays
# over paths it blocks writes to) are stripped from the hash on both sides.
# Without this, a ghost mount present at snapshot time but not at verify
# time (or vice versa, e.g. a different sandbox context between the two
# calls) changes the raw porcelain hash even though nothing in the tracked
# working tree actually changed — a false-positive worktree drift warning.
#
# mknod requires root/CAP_MKNOD and is unavailable in this (and most CI)
# environments, so tests simulate a ghost mount with a symlink to /dev/null
# (`ln -s /dev/null <path>`) — same technique as git-status-filtered.test.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

VERIFY="$SCRIPT_DIR/../scripts/post-review-state-verify.sh"
FILTER="$SCRIPT_DIR/../scripts/lib/git-status-filtered.sh"

echo "=== post-review-state-verify.sh (worktree drift axis, ghost-mount consistency) ==="

if [ ! -f "$VERIFY" ]; then
  echo "ERROR: $VERIFY not found" >&2
  exit 1
fi

cleanup_dirs=()
cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

# Snapshot helper: mirrors the exact command pr-review SKILL.md ステップ 4.0.A
# uses for ORIG_WTH — filtered porcelain output piped to md5sum.
snapshot_hash() {
  local dir="$1"
  ( cd "$dir" && bash "$FILTER" 2>/dev/null | md5sum | awk '{print $1}' )
}

# --- Baseline: clean tree, no drift at all -----------------------------------
sbx0=$(make_sandbox) && cleanup_dirs+=("$sbx0") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
branch0=$(cd "$sbx0" && git branch --show-current)
wth0=$(snapshot_hash "$sbx0")
out0=$(cd "$sbx0" && bash "$VERIFY" --original-branch "$branch0" --original-worktree-hash "$wth0" --auto-recover true)
drift0=$(printf '%s' "$out0" | jq -r '.drift' 2>/dev/null)
assert "baseline: clean tree reports drift=false" "false" "$drift0"

# --- T-01 (AC-1): ghost-mount-only difference between snapshot and verify time
#     must NOT be reported as drift -------------------------------------------
sbx1=$(make_sandbox) && cleanup_dirs+=("$sbx1") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
branch1=$(cd "$sbx1" && git branch --show-current)
wth1=$(snapshot_hash "$sbx1")
# Simulate a ghost mount appearing between snapshot and verify (e.g. a
# different sandbox context at verify time overlaying a write-block mount).
( cd "$sbx1" && ln -s /dev/null ghost_devnull ) >/dev/null 2>&1
out1=$(cd "$sbx1" && bash "$VERIFY" --original-branch "$branch1" --original-worktree-hash "$wth1" --auto-recover true)
drift1=$(printf '%s' "$out1" | jq -r '.drift' 2>/dev/null)
assert "T-01: ghost-mount-only diff reports drift=false" "false" "$drift1"

# --- T-02 (AC-2): a real tracked-file edit between snapshot and verify time
#     MUST still be reported as worktree drift --------------------------------
sbx2=$(make_sandbox) && cleanup_dirs+=("$sbx2") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
branch2=$(cd "$sbx2" && git branch --show-current)
wth2=$(snapshot_hash "$sbx2")
( cd "$sbx2" && echo changed >> a ) >/dev/null 2>&1
out2=$(cd "$sbx2" && bash "$VERIFY" --original-branch "$branch2" --original-worktree-hash "$wth2" --auto-recover true)
drift2=$(printf '%s' "$out2" | jq -r '.drift' 2>/dev/null)
type2=$(printf '%s' "$out2" | jq -r '.type' 2>/dev/null)
recovered2=$(printf '%s' "$out2" | jq -r '.recovered' 2>/dev/null)
assert "T-02: real tracked-file edit reports drift=true" "true" "$drift2"
assert "T-02: drift type is worktree" "worktree" "$type2"
assert "T-02: worktree drift is not auto-recovered" "false" "$recovered2"

# --- T-02b: ghost mount + real edit together still detects the real drift ---
sbx3=$(make_sandbox) && cleanup_dirs+=("$sbx3") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
branch3=$(cd "$sbx3" && git branch --show-current)
wth3=$(snapshot_hash "$sbx3")
( cd "$sbx3" && ln -s /dev/null ghost_devnull && echo changed >> a ) >/dev/null 2>&1
out3=$(cd "$sbx3" && bash "$VERIFY" --original-branch "$branch3" --original-worktree-hash "$wth3" --auto-recover true)
drift3=$(printf '%s' "$out3" | jq -r '.drift' 2>/dev/null)
type3=$(printf '%s' "$out3" | jq -r '.type' 2>/dev/null)
assert "T-02b: real edit alongside ghost mount still reports drift=true" "true" "$drift3"
assert "T-02b: drift type is worktree" "worktree" "$type3"

print_summary "$(basename "$0")"
