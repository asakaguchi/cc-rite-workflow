#!/bin/bash
# Static / offline drift + consistency tests for the `/rite:init --upgrade` config
# follow-through (Issue #1446).
#
# Verifies:
#   T-10 (AC-10): every active top-level key in the template above the
#        `# --- Advanced (below this line) ---` marker is enumerated in init.md's
#        "Active top-level sections covered on --upgrade" drift anchor. A new
#        template section that is not listed in init.md fails this test, forcing
#        init.md to be updated so `--upgrade` does not silently miss it.
#   T-11 (AC-11): the template and init.md agree that `multi_session:` is
#        back-added on --upgrade (with `enabled: true`), and no stale "do NOT
#        back-add" / "NOT back-added" / "left absent" wording survives in either
#        file.
#
# Usage: bash plugins/rite/hooks/tests/init-upgrade-drift.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
INIT_MD="$REPO_ROOT/plugins/rite/commands/init.md"
TEMPLATE="$REPO_ROOT/plugins/rite/templates/config/rite-config.yml"

PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); echo "  ✗ $1" >&2; }

assert_contains() { # file pattern description
  if grep -qE -e "$2" "$1"; then pass "$3"; else fail "$3 (missing pattern: $2)"; fi
}
assert_absent() { # file fixed-string description
  if grep -qF -- "$2" "$1"; then fail "$3 (stale text present: $2)"; else pass "$3"; fi
}

# --- Preconditions ---
[ -f "$INIT_MD" ]   || { echo "FATAL: init.md not found at $INIT_MD" >&2; exit 1; }
[ -f "$TEMPLATE" ]  || { echo "FATAL: template not found at $TEMPLATE" >&2; exit 1; }

echo "=== T-10: template active top-level sections ⊆ init.md upgrade enumeration ==="

# Active top-level keys in the template above the Advanced boundary.
template_sections=$(awk '
  /# --- Advanced \(below this line\) ---/ { exit }
  /^[a-z_]+:/ { key=$0; sub(/:.*/, "", key); print key }
' "$TEMPLATE")

[ -n "$template_sections" ] || { echo "FATAL: no template sections extracted (parser drift?)" >&2; exit 1; }

# The init.md drift anchor line (single source of the enumeration).
enum_line=$(grep -nF 'Active top-level sections covered on --upgrade' "$INIT_MD" | head -1 | cut -d: -f1 || true)
if [ -z "$enum_line" ]; then
  fail "init.md is missing the 'Active top-level sections covered on --upgrade' drift anchor"
else
  pass "init.md drift anchor present"
  enum_text=$(sed -n "${enum_line}p" "$INIT_MD")
  for sec in $template_sections; do
    if printf '%s' "$enum_text" | grep -qF -- "\`$sec\`"; then
      pass "template section '$sec' is enumerated in init.md"
    else
      fail "template section '$sec' is NOT enumerated in init.md upgrade handling"
    fi
  done
fi

echo "=== T-11: multi_session back-add wording is consistent (no stale text) ==="

# Positive: both files state the back-add policy.
assert_contains "$INIT_MD" 'multi_session.*[Bb]ack-add on --upgrade with .enabled: true.' \
  "init.md Step 4 row states multi_session is back-added with enabled: true"
assert_contains "$TEMPLATE" 'back-added with .enabled: true.' \
  "template comment states multi_session is back-added with enabled: true on --upgrade"

# Negative: no stale "do not back-add" wording remains.
assert_absent "$INIT_MD" 'Do NOT back-add on --upgrade' \
  "init.md no longer says 'Do NOT back-add on --upgrade'"
assert_absent "$TEMPLATE" 'intentionally NOT back-added' \
  "template no longer says 'intentionally NOT back-added'"
assert_absent "$INIT_MD" 'left absent' \
  "init.md no longer says multi_session is 'left absent' on upgrade"

# --- Summary ---
echo ""
echo "==============================="
echo "init-upgrade-drift: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
echo "All init-upgrade-drift checks passed!"
