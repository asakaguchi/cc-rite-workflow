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
START_MD="$REPO_ROOT/plugins/rite/commands/issue/start.md"
START_FINALIZE_MD="$REPO_ROOT/plugins/rite/commands/issue/start-finalize.md"

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

for f in "$POST_COMPACT_SH" "$PRE_COMPACT_SH" "$START_MD" "$START_FINALIZE_MD"; do
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
echo "[T-2/7f] 3-site PR delete vs auth/network 判別 regex (post-compact.sh / start.md / start-finalize.md)"
# 3-site 対称化 verification: gh CLI 実出力 `Could not resolve to a PullRequest` (CamelCase 連結) に
# マッチする regex を 3 site 全てで literal pin する。drift が起きても全 site の test が同時に fail する。
#
# Single Source of Truth: 期待 regex を変数で 1 度だけ定義し、(a) literal pin、(b) positive case、
# (c) negative case の 3 箇所で同じ値を参照する。source の regex が拡張された場合に literal pin が
# fail することで drift を検出する設計。L99/L130/L150 で同じ EXPECTED_REGEX を再利用する。
EXPECTED_REGEX='could not resolve.*pull\s*request|no.*pull\s*request found'

# assert_file_contains に渡す pattern について (保守者向け):
# - pattern は single-quote で書く (bash 展開なし)、内側の `\.` `\*` `\|` は backslash + 文字として
#   そのまま grep -E に渡る
# - grep -E ERE: `\.` `\*` `\|` はそれぞれ literal `.` `*` `|` を要求 (escape ありで literal 化)
# - `\s` は GNU grep の拡張 character class で「whitespace 1 文字」、`\\s\*` は `\s` の後に literal `*`
# - ファイル内に源 regex (`could not resolve.*pull\s*request|no.*pull\s*request found`) が
#   そのままの literal 文字列として書かれていることを verify するための pattern
for site in "$POST_COMPACT_SH" "$START_MD" "$START_FINALIZE_MD"; do
  site_basename=$(basename "$site")
  assert_file_contains "$site" 'could not resolve\.\*pull\\s\*request\|no\.\*pull\\s\*request found' \
    "$site_basename has space-less PullRequest variant regex (3-site symmetry)"
  # 旧 regex の literal フォーマット (元の 3 alternative、`not found` 単体含む固定順序) を fixed-string
  # match で detect。alternative の順序を入れ替えた variant は detect しない設計 (3-site literal pin が
  # drift gate として機能するため、site 側の regex 変更は L99 assertion で必ず fail する)。
  if grep -qF "'no.*pull request found|could not resolve.*pull request|not found'" "$site"; then
    FAIL=$((FAIL + 1))
    FAILURES+=("$site_basename still contains old overbroad regex with 'not found' alternative")
    echo "  ✗ $site_basename old regex (with 'not found') removed" >&2
  else
    PASS=$((PASS + 1))
    echo "  ✓ $site_basename old regex (with 'not found') removed"
  fi
done

# === positive test cases (削除済み PR として正しく分類されるべき出力) ===
# regex は `-i` flag で大文字小文字無視するため、大文字小文字混在 fixture も追加 (`-i` 削除 regression 防止)
# EXPECTED_REGEX を参照することで source/test/inline 検証の 3 箇所同期を保つ。
for fixture in \
    "Could not resolve to a PullRequest with the number of 999999999." \
    "Could not resolve to a Pull Request with the number of 999999999." \
    "GraphQL: Could not resolve to a PullRequest with the number of 999999999. (repository.pullRequest)" \
    "no pull request found for branch 'foo/bar'" \
    "no PullRequest found for the given ref" \
    "Could NOT Resolve to a PULLREQUEST"; do
  if printf '%s' "$fixture" | grep -qiE "$EXPECTED_REGEX"; then
    PASS=$((PASS + 1))
    echo "  ✓ regex matches: $fixture (classified as pr_deleted_or_inaccessible)"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("regex does NOT match positive case: $fixture")
    echo "  ✗ regex does NOT match positive case: $fixture" >&2
  fi
done

# === negative test cases (auth/network/permission failure として分類されるべき出力) ===
# regex が `.*pull\s*request` で広く取るため、pull request を含む non-deletion error の
# false positive を検出する。
# 注: F-08 cycle 1 で導入された `unable to access pull request: network timeout (permission denied)` は、
# regex の prefix anchor (`could not resolve` または `no...pull request found`) のいずれにも該当しないため
# rejected される (pull request 単体 mention や permission denied 文字列単独で false positive を出さないことを demonstrate)。
for fixture in \
    "network error: timeout" \
    "HTTP 404: Repository not found" \
    "HTTP 403: rate limit exceeded" \
    "" \
    "unable to access pull request: network timeout (permission denied)" \
    "permission denied"; do
  if printf '%s' "$fixture" | grep -qiE "$EXPECTED_REGEX"; then
    FAIL=$((FAIL + 1))
    FAILURES+=("regex INCORRECTLY matches negative case: '$fixture'")
    echo "  ✗ regex INCORRECTLY matches negative case: '$fixture' (false positive)" >&2
  else
    PASS=$((PASS + 1))
    echo "  ✓ regex correctly rejects: '$fixture' (classified as gh_api_failure_*)"
  fi
done

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
