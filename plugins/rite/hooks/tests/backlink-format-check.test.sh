#!/bin/bash
# Tests for hooks/scripts/backlink-format-check.sh (Issue #1719)
#
# The checker flags two legacy `Downstream reference:` dialects that the
# canonical colon form replaced:
#   P1 — space-separated: "<path> Phase N.N" instead of "<path>:Phase N.N"
#   P2 — parenthetical "(DRIFT-CHECK ANCHOR: ...)" qualifier
# These tests pin that the canonical colon form stays clean while both legacy
# dialects are still detected — the regression this lint exists to prevent.
#
# Convention: mktemp sandbox, no network, no gh, GNU/BSD portable. The checker
# resolves targets under --repo-root, so no git repo is needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../scripts/backlink-format-check.sh"

echo "=== backlink-format-check.sh tests ==="

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT not found" >&2
  exit 1
fi

SANDBOX="$(make_plain_sandbox)"
cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT INT TERM HUP

# --- Fixtures (paths relative to --repo-root sandbox) -------------------------
# Canonical colon form — must stay clean.
printf 'Some prose.\n<!-- Downstream reference: lint.md:Phase 8.3 -->\nMore prose.\n' \
  > "$SANDBOX/clean.md"
# P1 space-separated dialect — a space, not a colon, before "Phase".
printf '<!-- Downstream reference: lint.md Phase 8.3 -->\n' \
  > "$SANDBOX/ng-p1.md"
# P2 parenthetical DRIFT-CHECK ANCHOR qualifier on a Downstream reference line.
printf '<!-- Downstream reference: lint.md:Phase 8.3 (DRIFT-CHECK ANCHOR: foo) -->\n' \
  > "$SANDBOX/ng-p2.md"

run() { bash "$SCRIPT" --repo-root "$SANDBOX" "$@" >/dev/null 2>&1; echo $?; }

# --- Invocation contract ------------------------------------------------------
assert "--help exits 0" "0" "$(bash "$SCRIPT" --help >/dev/null 2>&1; echo $?)"
assert "no targets exits 2 (invocation error)" "2" "$(run --quiet)"
assert "unknown argument exits 2" "2" "$(run --bogus)"

# --- Clean canonical form -----------------------------------------------------
assert "canonical colon form is clean (exit 0)" "0" "$(run --quiet --target clean.md)"

# --- Legacy dialect detection -------------------------------------------------
assert "P1 space-separated dialect detected (exit 1)" "1" "$(run --quiet --target ng-p1.md)"
assert "P2 parenthetical qualifier detected (exit 1)" "1" "$(run --quiet --target ng-p2.md)"

# --- Finding output names the pattern -----------------------------------------
p1_out="$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet --target ng-p1.md 2>/dev/null || true)"
if printf '%s' "$p1_out" | grep -qF '[backlink-format][P1]'; then
  pass "P1 finding is tagged [backlink-format][P1]"
else
  fail "P1 finding tag missing: $p1_out"
fi
p2_out="$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet --target ng-p2.md 2>/dev/null || true)"
if printf '%s' "$p2_out" | grep -qF '[backlink-format][P2]'; then
  pass "P2 finding is tagged [backlink-format][P2]"
else
  fail "P2 finding tag missing: $p2_out"
fi

print_summary "backlink-format-check.sh"
