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
# ERE escape (`\-\-arg`) でリテラル match させ、`--` を pattern token として誤認させない。
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
echo "[T-2/7f] post-compact.sh F-12 regex matches gh CLI actual output (Issue #1008)"
# Regex literal pin: cycle 11 F-01 で導入された空白なし変種対応 regex を verify
# gh CLI 実出力 `Could not resolve to a PullRequest` (CamelCase 連結) にマッチする regex は
# `pull\s*request` で空白あり/なし両対応であること
assert_file_contains "$POST_COMPACT_SH" 'could not resolve\.\*pull\\s\*request\|no\.\*pull\\s\*request found' \
  "post-compact.sh has F-12 regex with \\s* for space-less PullRequest variant (Issue #1008)"
# overbroad な `not found` alternative が削除されていることを verify
if grep -qF "'no.*pull request found|could not resolve.*pull request|not found'" "$POST_COMPACT_SH"; then
  FAIL=$((FAIL + 1))
  FAILURES+=("post-compact.sh still contains old overbroad regex with 'not found' alternative")
  echo "  ✗ post-compact.sh old regex (with 'not found') removed" >&2
else
  PASS=$((PASS + 1))
  echo "  ✓ post-compact.sh old regex (with 'not found') removed"
fi
# 実出力でのマッチ動作確認 (regex を実行して semantics を verify)
gh_actual_output="Could not resolve to a PullRequest with the number of 999999999."
if printf '%s' "$gh_actual_output" | grep -qiE 'could not resolve.*pull\s*request|no.*pull\s*request found'; then
  PASS=$((PASS + 1))
  echo "  ✓ regex matches gh CLI actual output 'Could not resolve to a PullRequest' (classifies as pr_deleted_or_inaccessible)"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("regex does not match gh CLI actual output 'Could not resolve to a PullRequest'")
  echo "  ✗ regex does not match gh CLI actual output" >&2
fi
# network error 等の other failure が pr_deleted_or_inaccessible に誤分類されないこと
network_err="network error: timeout"
if printf '%s' "$network_err" | grep -qiE 'could not resolve.*pull\s*request|no.*pull\s*request found'; then
  FAIL=$((FAIL + 1))
  FAILURES+=("regex incorrectly matches network error 'network error: timeout' (false positive)")
  echo "  ✗ regex incorrectly matches network error (false positive)" >&2
else
  PASS=$((PASS + 1))
  echo "  ✓ regex does not match network error (classifies as post_compact_gh_pr_view_failed)"
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
