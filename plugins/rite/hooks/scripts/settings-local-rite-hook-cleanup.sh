#!/bin/bash
# rite workflow - settings.local.json rite hook cleanup
#
# Removes stale legacy rite hook entries from .claude/settings.local.json when
# native hooks.json management is in effect (commands/init.md Phase 4.5.0.2).
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
#                  python3 unavailable / invalid JSON) — file left untouched
#
# Exit codes:
#   0  always (non-blocking; status conveyed via the stdout token)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
  if mv "$tmp" "$settings" 2>/dev/null; then
    echo "CLEANED"
  else
    echo "NO_RITE_HOOKS"
  fi
else
  echo "NO_RITE_HOOKS"
fi
