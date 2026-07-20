#!/bin/bash
# sandbox-ghost-dirty-integration.test.sh (#1936, T-04 / T-06)
#
# Pins that the exact dirty-detection lines embedded in cleanup/SKILL.md
# Step 4-W and recover/SKILL.md Phase 3.2 — extracted literally from the
# SKILL.md files, not reimplemented — resolve to "not dirty" when the only
# `??` entries in the tree are sandbox write-block ghost mounts, and still
# resolve to "dirty" for a genuine untracked file (no false-negative
# regression). T-05 (cleanup Step 4 BASE_UPDATE=ok under the same ghost-only
# condition) is covered by base-update-classify.test.sh's dedicated case.
#
# mknod requires root/CAP_MKNOD (unavailable here and in most CI), so a
# symlink to /dev/null simulates the ghost mount: `test -c` follows
# symlinks (like stat, not lstat), so a symlink target of /dev/null is
# indistinguishable from the real character-device bind mount for the one
# property lib/git-status-filtered.sh inspects, and `git status --porcelain`
# reports it as an ordinary `??` entry exactly like the genuine ghost mount.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
CLEANUP_MD="$PLUGIN_ROOT/skills/cleanup/SKILL.md"
RECOVER_MD="$PLUGIN_ROOT/skills/recover/SKILL.md"

echo "=== sandbox ghost-mount dirty-check integration (cleanup Step 4-W / recover) ==="

cleanup_dirs=()
cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

# --- Extract the exact dirty-detection line from each SKILL.md, literally,
#     so drift in the source file (not just this test) is caught -----------
CLEANUP_LINE=$(grep -m1 '^\s*dirty=\$(bash {plugin_root}' "$CLEANUP_MD")
if [ -z "$CLEANUP_LINE" ]; then
  echo "ERROR: cleanup/SKILL.md からの dirty= 行抽出に失敗しました（アンカーが変更された可能性）" >&2
  exit 1
fi
CLEANUP_LINE=${CLEANUP_LINE//\{plugin_root\}/$PLUGIN_ROOT}

RECOVER_LINE=$(grep -m1 'git_has_uncommitted=\$(bash {plugin_root}' "$RECOVER_MD")
if [ -z "$RECOVER_LINE" ]; then
  echo "ERROR: recover/SKILL.md からの git_has_uncommitted= 行抽出に失敗しました（アンカーが変更された可能性）" >&2
  exit 1
fi
RECOVER_LINE=${RECOVER_LINE//\{plugin_root\}/$PLUGIN_ROOT}

run_cleanup_dirty() {
  # Mirrors the SKILL.md line's own variable name ("dirty") so the extracted
  # text runs unmodified; echoes it out for the test to capture.
  ( cd "$1" && eval "$CLEANUP_LINE" && printf '%s' "$dirty" )
}

run_recover_uncommitted() {
  ( cd "$1" && eval "$RECOVER_LINE" && printf '%s' "$git_has_uncommitted" )
}

# --- T-04: cleanup Step 4-W dirty line, ghost-only tree -> empty (not dirty)
sbx_t04=$(make_sandbox) && cleanup_dirs+=("$sbx_t04") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
( cd "$sbx_t04" && ln -s /dev/null ghost_devnull ) >/dev/null 2>&1
out=$(run_cleanup_dirty "$sbx_t04")
assert "T-04: cleanup Step 4-W dirty= is empty with ghost-only tree" "" "$out"

# --- T-04 regression guard: a genuine untracked file must still register --
sbx_t04b=$(make_sandbox) && cleanup_dirs+=("$sbx_t04b") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
( cd "$sbx_t04b" && echo x > real.txt ) >/dev/null 2>&1
out=$(run_cleanup_dirty "$sbx_t04b")
assert "T-04 regression guard: real untracked file still reported dirty" "?? real.txt" "$out"

# --- T-06: recover git_has_uncommitted, ghost-only tree -> empty ("なし") -
sbx_t06=$(make_sandbox) && cleanup_dirs+=("$sbx_t06") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
( cd "$sbx_t06" && ln -s /dev/null ghost_devnull ) >/dev/null 2>&1
out=$(run_recover_uncommitted "$sbx_t06")
assert "T-06: recover git_has_uncommitted is empty with ghost-only tree" "" "$out"

# --- T-06 regression guard: a genuine unstaged change must still register -
sbx_t06b=$(make_sandbox) && cleanup_dirs+=("$sbx_t06b") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
( cd "$sbx_t06b" && echo modified >> a ) >/dev/null 2>&1
out=$(run_recover_uncommitted "$sbx_t06b")
assert "T-06 regression guard: real unstaged change still reported uncommitted" " M a" "$out"

print_summary "$(basename "$0")"
