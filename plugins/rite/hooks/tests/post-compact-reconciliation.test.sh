#!/bin/bash
# Static tests for Issue #1003 AC-2 / AC-7: post-compact reconciliation safety net.
#
# Verifies:
#   T-2/7a: post-compact.sh has the reconciliation block (literal pin)
#   T-2/7b: post-compact.sh references projects-status-update.sh for reconcile
#   T-2/7c: post-compact.sh emits projects_status_in_review_missing on failure
#   T-2/7d: post-compact.sh script syntax is valid (bash -n)
#   T-2/7e: pre-compact.sh emits snapshot diag log
#
# Usage: bash plugins/rite/hooks/tests/post-compact-reconciliation.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
POST_COMPACT_SH="$REPO_ROOT/plugins/rite/hooks/post-compact.sh"
PRE_COMPACT_SH="$REPO_ROOT/plugins/rite/hooks/pre-compact.sh"

PASS=0
FAIL=0
FAILURES=()

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if grep -qE -e "$pattern" "$file"; then
    PASS=$((PASS + 1))
    echo "  ✓ $description"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$description (file: $(basename "$file"), pattern: $pattern)")
    echo "  ✗ $description" >&2
  fi
}

echo "=== T-2/T-7: post-compact reconciliation safety net (Issue #1003) ==="

for f in "$POST_COMPACT_SH" "$PRE_COMPACT_SH"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required file not found: $f" >&2
    exit 1
  fi
done

echo ""
echo "[T-2/7a] post-compact.sh reconciliation block exists"
assert_file_contains "$POST_COMPACT_SH" 'post-compact reconciliation' \
  "post-compact.sh has reconciliation safety net (AC-2/AC-7 literal pin)"
assert_file_contains "$POST_COMPACT_SH" 'post-compact mismatch detected' \
  "post-compact.sh logs mismatch detection (observability)"

echo ""
echo "[T-2/7b] post-compact.sh delegates to projects-status-update.sh"
assert_file_contains "$POST_COMPACT_SH" 'projects-status-update\.sh' \
  "post-compact.sh invokes projects-status-update.sh for reconcile"
# Verify the call passes status_name="In Review" in jq -n input JSON
assert_file_contains "$POST_COMPACT_SH" 'status_name:\$status' \
  "post-compact.sh passes status_name in jq -n input JSON"
# Issue #1003 review F-04 修正: 旧コードは `assert_file_contains $SH -- '--arg status "In Review"'`
# で `--` が pattern に固定され trivially match。canonical 3-arg signature に揃え、ダッシュを含む
# 部分を ERE escape (`\-\-arg`) でリテラル match させる。
assert_file_contains "$POST_COMPACT_SH" '\-\-arg status "In Review"' \
  "post-compact.sh reconcile target is In Review"

echo ""
echo "[T-2/7c] post-compact.sh emits sentinel on reconcile failure"
assert_file_contains "$POST_COMPACT_SH" 'workflow-incident-emit\.sh' \
  "post-compact.sh invokes workflow-incident-emit.sh"
assert_file_contains "$POST_COMPACT_SH" 'projects_status_in_review_missing' \
  "post-compact.sh emits projects_status_in_review_missing"
assert_file_contains "$POST_COMPACT_SH" 'post_compact_reconciliation_failed' \
  "post-compact.sh emits root_cause_hint=post_compact_reconciliation_failed"

echo ""
echo "[T-2/7d] post-compact.sh syntax is valid"
if bash -n "$POST_COMPACT_SH" 2>/dev/null; then
  PASS=$((PASS + 1))
  echo "  ✓ post-compact.sh: bash -n passes"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("post-compact.sh: bash -n failed")
  echo "  ✗ post-compact.sh: bash -n failed" >&2
fi

echo ""
echo "[T-2/7e] pre-compact.sh emits snapshot diag log"
assert_file_contains "$PRE_COMPACT_SH" 'PRE_COMPACT_SNAPSHOT_RECORDED=1' \
  "pre-compact.sh emits PRE_COMPACT_SNAPSHOT_RECORDED=1 sentinel on success"
assert_file_contains "$PRE_COMPACT_SH" 'PRE_COMPACT_SNAPSHOT_FAILED=1' \
  "pre-compact.sh emits PRE_COMPACT_SNAPSHOT_FAILED=1 sentinel on failure"
if bash -n "$PRE_COMPACT_SH" 2>/dev/null; then
  PASS=$((PASS + 1))
  echo "  ✓ pre-compact.sh: bash -n passes"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("pre-compact.sh: bash -n failed")
  echo "  ✗ pre-compact.sh: bash -n failed" >&2
fi

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
echo "All post-compact reconciliation checks passed."
