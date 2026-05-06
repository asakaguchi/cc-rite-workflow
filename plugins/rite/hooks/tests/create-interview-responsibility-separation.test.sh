#!/bin/bash
# create-interview-responsibility-separation.test.sh
#
# Negative test guarding the responsibility separation invariant
# declared in commands/issue/create-interview.md (Caller Return
# Protocol section, around line 307):
#
#   "bash block 側コメント (🚨 MANDATORY Pre-flight / Return Output Format)
#    は bash 引数 symmetry のみを inline 言及し、HTML literal symmetry は
#    本セクションを single source として参照する責務分離を維持する。"
#
# Issue #861 — machine-verifiable enforcement of the invariant declared at
# create-interview.md line 307. Without this test, the line 307 declaration
# could silently drift if a future commit added an HTML-literal-symmetry
# test reference to a bash block comment, defeating the SoT structure.
#
# What this test verifies:
#   1. NEGATIVE: bash fenced blocks (```bash ... ```) in create-interview.md
#      MUST NOT contain the string `caller-html-literal-symmetry` —
#      the HTML literal symmetry test reference belongs only in the prose
#      Caller Return Protocol section, not in bash block comments.
#   2. POSITIVE: prose sections (outside bash fenced blocks) MUST contain
#      at least one reference to `caller-html-literal-symmetry` —
#      this guards against accidental deletion of the SoT reference.
#
# When this test fails:
#   The responsibility separation between bash block comments and the
#   prose hub (line ~307) has drifted. Restore by either (a) removing
#   the HTML-literal-symmetry reference from the bash block, or (b)
#   restoring the missing SoT reference in the prose Caller Return
#   Protocol section. Do NOT relax this test — the invariant exists to
#   keep bash block comments focused on bash arg symmetry only.
#
# Relationship with sibling tests:
#   - `4-site-symmetry.test.sh` guards CLI-arg PRESENCE across sites.
#   - `caller-html-literal-symmetry.test.sh` guards byte equality of
#     the 2 HTML literal example blocks.
#   - This test guards the *meta-invariant* that wires the two above
#     into a single SoT hub at line 307.
#   The three are complementary; none subsumes the others.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

TARGET="$REPO_ROOT/plugins/rite/commands/issue/create-interview.md"
NEEDLE="caller-html-literal-symmetry"

PASS=0
FAIL=0
FAILED_NAMES=()

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  ❌ $1"; }

if [ ! -f "$TARGET" ]; then
  echo "  ❌ FILE NOT FOUND: $TARGET"
  exit 1
fi

echo "=== bash fenced block content extraction ==="
# Extract content inside ```bash ... ``` fences (exclusive of fence lines).
bash_block_content=$(awk '
  /^```bash$/      { in_bash=1; next }
  /^```$/ && in_bash { in_bash=0; next }
  in_bash          { print }
' "$TARGET")

if [ -z "$bash_block_content" ]; then
  fail "no bash fenced blocks found in $TARGET (file may have been restructured)"
else
  pass "bash fenced blocks extracted"
fi

echo
echo "=== NEGATIVE: bash blocks must NOT reference $NEEDLE ==="
if printf '%s\n' "$bash_block_content" | grep -qF "$NEEDLE"; then
  fail "bash block comments contain '$NEEDLE' reference (responsibility separation drift)"
  echo "  --- offending lines ---" >&2
  printf '%s\n' "$bash_block_content" | grep -nF "$NEEDLE" >&2
else
  pass "bash blocks do not reference $NEEDLE (responsibility separation preserved)"
fi

echo
echo "=== POSITIVE: prose sections MUST reference $NEEDLE (SoT preserved) ==="
prose_content=$(awk '
  /^```bash$/      { in_bash=1; next }
  /^```$/ && in_bash { in_bash=0; next }
  !in_bash         { print }
' "$TARGET")

if printf '%s\n' "$prose_content" | grep -qF "$NEEDLE"; then
  pass "prose sections retain the SoT reference to $NEEDLE"
else
  fail "prose sections missing $NEEDLE reference (Caller Return Protocol hub broken)"
fi

echo
echo "─── $(basename "$0") summary ──────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -ne 0 ]; then
  echo "Failed assertions:"
  for n in "${FAILED_NAMES[@]}"; do
    echo "  - $n"
  done
  echo
  echo "⚠️ Responsibility separation drift detected at create-interview.md."
  echo "   bash block comments must not reference $NEEDLE — the HTML"
  echo "   literal symmetry hub is the prose Caller Return Protocol"
  echo "   section (around line 307). Restore symmetry by removing"
  echo "   the bash-block reference or restoring the prose SoT reference."
  exit 1
fi

echo "OK: responsibility separation invariant preserved"
exit 0
