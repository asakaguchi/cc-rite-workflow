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
#   T-12 (Issue #1448): every DIRECT sub-key of each active top-level section
#        (above the `# --- Advanced ---` marker) is enumerated in init.md's
#        "Active sub-keys covered on --upgrade" drift anchor, under its section's
#        row. This extends T-10's protection one level down: a new sub-key added
#        to an existing template section that init.md fails to list fails this
#        test, forcing init.md to be updated so `--upgrade` does not silently
#        miss it (mirrors the sub-key merge rule, init.md Step 6 item 4).
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
# Key regex allows digits/hyphens after the first char (e.g. a future `oauth2:`),
# a strict superset of the current all-lowercase keys so this does not change
# T-10's extraction for today's template.
template_sections=$(awk '
  /# --- Advanced \(below this line\) ---/ { exit }
  /^[a-z_][a-zA-Z0-9_-]*:/ { key=$0; sub(/:.*/, "", key); print key }
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

echo "=== T-12: template active section direct sub-keys ⊆ init.md sub-key drift anchor ==="

# Direct (exactly 2-space indented) sub-keys per active top-level section in the
# template, emitted as "section.subkey". Deeper-nested keys (4+ spaces) and list
# items are excluded so only one level below each section is asserted.
template_subkeys=$(awk '
  /# --- Advanced \(below this line\) ---/ { exit }
  /^[a-z_][a-zA-Z0-9_-]*:/ { section=$0; sub(/:.*/, "", section); next }
  /^  [a-z_][a-zA-Z0-9_-]*:/ { key=$0; sub(/^  /, "", key); sub(/:.*/, "", key); print section "." key }
' "$TEMPLATE")

[ -n "$template_subkeys" ] || { echo "FATAL: no template sub-keys extracted (parser drift?)" >&2; exit 1; }

# The init.md sub-key drift anchor block: from the marker line through its closing
# "When a new sub-key is added" guard line (single source of the enumeration).
sub_anchor_start=$(grep -nF 'Active sub-keys covered on --upgrade' "$INIT_MD" | head -1 | cut -d: -f1 || true)
if [ -z "$sub_anchor_start" ]; then
  fail "init.md is missing the 'Active sub-keys covered on --upgrade' drift anchor"
else
  pass "init.md sub-key drift anchor present"
  sub_anchor_end=$(awk -v s="$sub_anchor_start" 'NR>s && /When a new sub-key is added/ { print NR; exit }' "$INIT_MD")
  [ -n "$sub_anchor_end" ] || sub_anchor_end=$(wc -l < "$INIT_MD")
  anchor_block=$(sed -n "${sub_anchor_start},${sub_anchor_end}p" "$INIT_MD")

  for pair in $template_subkeys; do
    sec=${pair%%.*}
    key=${pair#*.}
    # The anchor row for this section, e.g. "- `review`: `min_reviewers`, ...".
    row=$(printf '%s\n' "$anchor_block" | grep -F -- "- \`$sec\`:" | head -1 || true)
    if [ -z "$row" ]; then
      fail "init.md sub-key anchor has no row for section '$sec' (needed for '$pair')"
    elif printf '%s' "$row" | grep -qF -- "\`$key\`"; then
      pass "template sub-key '$pair' is enumerated in init.md"
    else
      fail "template sub-key '$pair' is NOT enumerated in init.md sub-key anchor"
    fi
  done
fi

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
