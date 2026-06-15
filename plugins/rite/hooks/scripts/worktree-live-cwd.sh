#!/bin/bash
# worktree-live-cwd.sh — OS-ground-truth liveness probe for a worktree directory.
#
# Answers a single question: "is any live process standing in this directory
# (cwd at it or nested under it)?" — independent of rite's own flow-state
# bookkeeping.
#
# Why this exists (Issue #1544, regression of #1524):
#   When a session enters a session worktree via `EnterWorktree`, the harness
#   records that worktree as the session's cwd and restores it on `/clear`. If the
#   worktree is removed (cross-session lazy reap in pr-cycle-cleanup.sh Step 5, or
#   a cleanup from a different cwd in cleanup.md Step 4-W) while the owning
#   session's harness cwd still points there, `/clear` fails with
#   `Error: Path "..." does not exist`. #1524's guards key off flow-state
#   (`active` flag + `worktree` field); those can DRIFT from where harness cwds
#   actually are (active=false but still standing in it, empty/nulled `worktree`
#   field, stale session-id). This probe does not depend on that bookkeeping — it
#   reads the OS's own record of each process's cwd, so "don't delete a tree
#   someone is standing in" holds even when flow-state is wrong.
#
# Usage:
#   worktree-live-cwd.sh <dir>
#
# Exit codes:
#   0 = a live process has cwd == <dir> or nested under it  → DO NOT remove
#   1 = no live process is standing in <dir>                → safe (per other gates)
#   2 = cannot determine (no /proc and no lsof)             → caller decides
#
# Portability: avoids GNU `realpath` (canonicalizes via `cd && pwd -P`) to keep
# the macOS bash 3.2 floor shared with pr-cycle-cleanup.sh. `/proc` is the
# primary source (Linux); `lsof` is the fallback (BSD/macOS). Same-user processes
# are readable, and Claude Code sessions run as the same user.
set -uo pipefail

target="${1:-}"
if [ -z "$target" ]; then
  echo "ERROR: worktree-live-cwd.sh: <dir> argument required" >&2
  exit 2
fi

# Canonicalize. A non-directory target (already-removed path) falls back to its
# raw string so a string comparison still has something to match against.
if [ -d "$target" ]; then
  target_canon=$( cd -- "$target" 2>/dev/null && pwd -P ) || target_canon="$target"
else
  target_canon="$target"
fi
[ -n "$target_canon" ] || target_canon="$target"

# Primary: Linux /proc. readlink of /proc/<pid>/cwd is the OS ground truth for a
# process's working directory. This script's own cwd is the caller's (repo root
# for the reaper, main checkout for cleanup), never the candidate worktree, so it
# does not false-match itself — and the reaper's own active worktree is already
# excluded upstream (Gate 0 self-exclusion) before this probe is consulted.
if [ -d /proc ]; then
  for _pdir in /proc/[0-9]*; do
    _cwd=$(readlink "$_pdir/cwd" 2>/dev/null) || continue
    [ -n "$_cwd" ] || continue
    [ "$_cwd" = "$target_canon" ] && exit 0
    # Trailing-slash prefix test: `issue-1` must not match `issue-12`.
    case "$_cwd/" in
      "$target_canon"/*) exit 0 ;;
    esac
  done
  exit 1
fi

# Fallback: lsof (where /proc is absent). `-a -d cwd +D <dir>` lists processes
# whose working directory is at or under <dir>; any hit means a live cwd.
if command -v lsof >/dev/null 2>&1; then
  if lsof -a -d cwd +D "$target_canon" >/dev/null 2>&1; then
    exit 0
  fi
  exit 1
fi

# Neither /proc nor lsof — undeterminable.
exit 2
