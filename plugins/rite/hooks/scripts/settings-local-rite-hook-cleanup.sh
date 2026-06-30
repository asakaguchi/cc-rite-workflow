#!/bin/bash
# rite workflow - settings.local.json rite hook cleanup
#
# Removes stale legacy rite hook entries from .claude/settings.local.json when
# native hooks.json management is in effect (skills/init/SKILL.md Phase 4.5.0.2).
# The JSON transform is delegated to settings-local-rite-hook-cleanup.py
# (stdin->stdout); this wrapper owns the python3 guard and the atomic
# mktemp+mv write so the file is never left half-written.
#
# Usage:
#   bash settings-local-rite-hook-cleanup.sh <settings_local_path>
#
# Output (stdout) — machine-readable token for the init.md caller:
#   CLEANED        rite hook entries removed; file rewritten atomically
#   NO_RITE_HOOKS  nothing removed (no hooks / no rite hooks / file absent /
#                  python3 unavailable / invalid JSON / mv failed) — file left
#                  untouched. On mv failure a stderr WARNING is also emitted:
#                  the cleaned content was computed but could not be swapped in,
#                  so stale rite hooks remain (not actually "already clean").
#
# Exit codes:
#   0  always (non-blocking; status conveyed via the stdout token)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$SCRIPT_DIR/../control-char-neutralize.sh"
PYTHON_SCRIPT="$SCRIPT_DIR/settings-local-rite-hook-cleanup.py"

settings="${1:-}"
if [ -z "$settings" ] || [ ! -f "$settings" ] || ! command -v python3 >/dev/null 2>&1; then
  echo "NO_RITE_HOOKS"
  exit 0
fi

# tmp in the same dir as the target so mv is an atomic same-filesystem rename
tmp=$(mktemp "${settings}.XXXXXX" 2>/dev/null) || tmp=""
if [ -z "$tmp" ]; then
  echo "NO_RITE_HOOKS"
  exit 0
fi
trap 'rm -f "$tmp"' EXIT

# python3 exit 0 = changed (cleaned JSON on stdout); non-zero = no change / invalid
if python3 "$PYTHON_SCRIPT" < "$settings" > "$tmp" 2>/dev/null; then
  # Capture mv's stderr so EXDEV / EACCES / ENOSPC / SELinux deny stays
  # distinguishable (mktemp may fail under disk pressure — fall back to /dev/null).
  mv_err=$(mktemp 2>/dev/null) || mv_err=""
  if mv "$tmp" "$settings" 2>"${mv_err:-/dev/null}"; then
    echo "CLEANED"
  else
    # $? must be grabbed first — any later command would overwrite it. The file
    # is NOT clean here (stale rite hooks remain), so surface the failure on
    # stderr instead of silently folding to a misleading "already clean" token.
    # Pattern per issue-comment-wm-sync.sh:99-104.
    mv_rc=$?
    echo "NO_RITE_HOOKS"
    echo "[rite] WARNING: settings-local-rite-hook-cleanup: mv failed (rc=$mv_rc); legacy rite hooks left in place" >&2
    [ -n "$mv_err" ] && [ -s "$mv_err" ] && head -3 "$mv_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  fi
  [ -n "$mv_err" ] && rm -f "$mv_err"
else
  echo "NO_RITE_HOOKS"
fi

# Non-blocking contract: exit 0 explicitly so the script status never leaks the
# trailing `[ -n "$mv_err" ] && rm` result, which is 1 when the mv_err mktemp
# failed on the CLEANED path (the settings file was still rewritten correctly).
exit 0
