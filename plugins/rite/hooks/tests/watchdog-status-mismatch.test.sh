#!/bin/bash
# Static tests for Issue #1003 AC-9: watchdog-status-mismatch.sh
#
# Verifies:
#   T-9a: script exists and is executable
#   T-9b: script syntax is valid (bash -n)
#   T-9c: --help / -h prints usage without error
#   T-9d: --limit accepts numeric, rejects non-numeric
#   T-9e: required script flags are documented
#
# Usage: bash plugins/rite/hooks/tests/watchdog-status-mismatch.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WATCHDOG_SH="$REPO_ROOT/plugins/rite/scripts/watchdog-status-mismatch.sh"

PASS=0
FAIL=0
FAILURES=()

assert_cmd() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  ✓ $description"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$description (cmd: $*)")
    echo "  ✗ $description" >&2
  fi
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if grep -qE -e "$pattern" "$file"; then
    PASS=$((PASS + 1))
    echo "  ✓ $description"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$description (pattern: $pattern)")
    echo "  ✗ $description" >&2
  fi
}

echo "=== T-9: watchdog-status-mismatch.sh (Issue #1003 AC-9) ==="

echo ""
echo "[T-9a] Script exists and is executable"
if [ ! -f "$WATCHDOG_SH" ]; then
  echo "ERROR: $WATCHDOG_SH not found" >&2
  exit 1
fi
if [ -x "$WATCHDOG_SH" ]; then
  PASS=$((PASS + 1))
  echo "  ✓ watchdog-status-mismatch.sh is executable"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("watchdog-status-mismatch.sh is not executable")
  echo "  ✗ watchdog-status-mismatch.sh is not executable" >&2
fi

echo ""
echo "[T-9b] Script syntax is valid"
if bash -n "$WATCHDOG_SH" 2>/dev/null; then
  PASS=$((PASS + 1))
  echo "  ✓ bash -n passes"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("bash -n failed")
  echo "  ✗ bash -n failed" >&2
fi

echo ""
echo "[T-9c] --help prints usage"
help_output=$(bash "$WATCHDOG_SH" --help 2>&1) || true
if printf '%s' "$help_output" | grep -q 'watchdog-status-mismatch.sh'; then
  PASS=$((PASS + 1))
  echo "  ✓ --help prints usage including script name"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("--help output missing script name")
  echo "  ✗ --help output missing script name" >&2
fi

echo ""
echo "[T-9d] --limit input validation"
# Non-numeric should fail
if bash "$WATCHDOG_SH" --limit abc --dry-run --quiet >/dev/null 2>&1; then
  FAIL=$((FAIL + 1))
  FAILURES+=("--limit abc should fail")
  echo "  ✗ --limit abc should fail" >&2
else
  PASS=$((PASS + 1))
  echo "  ✓ --limit non-numeric is rejected"
fi

echo ""
echo "[T-9e] Documented flags present in source"
# Issue #1003 review F-03 修正: 旧コードは `assert_file_contains $SH -- '--flag' "desc"` 形式で、
# `--` が pattern として固定されて trivially match していた。canonical 3-arg signature に揃えるため、
# pattern は `\-\-{flag}\)` (case 句の閉じ括弧で固定) として cmd-line parse logic 自体を pin する。
assert_file_contains "$WATCHDOG_SH" '\-\-dry-run\)' \
  "Script case clause handles --dry-run flag"
assert_file_contains "$WATCHDOG_SH" '\-\-reconcile\)' \
  "Script case clause handles --reconcile flag"
assert_file_contains "$WATCHDOG_SH" '\-\-limit\)' \
  "Script case clause handles --limit flag"
assert_file_contains "$WATCHDOG_SH" '\-\-quiet\)' \
  "Script case clause handles --quiet flag"
# Issue #1003 AC-9 marker
assert_file_contains "$WATCHDOG_SH" 'Issue #1003 AC-9' \
  "Script header references Issue #1003 AC-9"
# Detection logic: isDraft=false && Status="In Progress"
assert_file_contains "$WATCHDOG_SH" 'isDraft' \
  "Script checks PR isDraft"
assert_file_contains "$WATCHDOG_SH" 'In Progress' \
  "Script checks Status == 'In Progress'"

echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failures:"
  for msg in "${FAILURES[@]}"; do
    echo "  - $msg"
  done
  exit 1
fi
echo "All watchdog-status-mismatch checks passed."
