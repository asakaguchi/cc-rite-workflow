#!/bin/bash
# post-compact-classification-regex.test.sh — CG-5 (PR #1079 verified-review re-port)
#
# Purpose:
#   旧 post-compact-reconciliation.test.sh (PR #1079 で削除) の中核 regex fixture test
#   を flat workflow 用に復元する。post-compact.sh は gh CLI 出力を分類して
#   `pr_deleted_or_inaccessible` (false-positive 抑止) vs `gh_api_failure_*` を判別する。
#
#   分類 regex: `could not resolve.*pull\s*request|no.*pull\s*request found`
#
#   regex を弱める / 取り除く / case-sensitive にすると、close/merge 済 PR への post-compact
#   reconciliation が偽 incident を量産する regression (cycle 6 で発覚) が再発する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
POST_COMPACT="$PLUGIN_ROOT/hooks/post-compact.sh"

[ -f "$POST_COMPACT" ] || { echo "ERROR: $POST_COMPACT not found" >&2; exit 1; }

# Extract the regex literal from post-compact.sh so the test exercises the actual production pattern.
# PR #1079 review (pr-test-analyzer S-3 対応): production regex を抽出して fixture grep に
# 実際に渡す。hard-code に頼ると post-compact.sh 側で regex を変更しても本 test は silent pass
# する drift が起きうるため、抽出した $REGEX を直接 fixture loop に渡して divergence を検出する。
# 抽出方法: production の `grep -qiE '<regex>'` 行から single-quote 内側だけを取り出す。
REGEX=$(grep -oE "grep -qiE '[^']+'" "$POST_COMPACT" | head -1 | sed -E "s/^grep -qiE '//; s/'\$//")
if [ -z "$REGEX" ]; then
  echo "ERROR: could not extract classification regex from $POST_COMPACT" >&2
  exit 1
fi

echo "=== Phase 1: post-compact.sh defines the canonical regex ==="
assert_grep "post-compact.sh contains canonical regex (could not resolve...pull request)" "$POST_COMPACT" "could not resolve.*pull"
assert_grep "post-compact.sh uses pr_deleted_or_inaccessible classification" "$POST_COMPACT" "pr_deleted_or_inaccessible"
assert_grep "post-compact.sh uses case-insensitive grep (-i flag for the regex)" "$POST_COMPACT" "grep -qiE"

echo "=== Phase 2: positive fixtures (must classify as pr_deleted_or_inaccessible) ==="
positive_fixtures=(
  "Could not resolve to a PullRequest with the number of 999999999."
  "could not resolve to a pull request with the number of 1234"
  "Could NOT Resolve to a PULLREQUEST"
  "No pull request found for branch foo"
  "no pull request found"
  "Could not resolve to a PullRequest"
  "GraphQL: Could not resolve to a PullRequest"
  "Error: could not resolve to a pull   request (multiple spaces)"
  "could not resolve to a PullRequest with extra trailing"
  "NO PULL REQUEST FOUND"
)
for fixture in "${positive_fixtures[@]}"; do
  # $REGEX (production から抽出) と hard-code regex の両方を確認することで、
  # post-compact.sh 側で regex を変更した時にこの test も同期更新する必要があることを明示する。
  if printf '%s' "$fixture" | grep -qiE "$REGEX"; then
    pass "positive (production regex): classify '$fixture'"
  else
    fail "positive (production regex): '$fixture' did NOT match (regex drift suspected: $REGEX)"
  fi
done

echo "=== Phase 3: negative fixtures (must NOT classify as pr_deleted_or_inaccessible) ==="
negative_fixtures=(
  "unable to access pull request: network timeout"
  "HTTP 403: rate limit exceeded"
  ""
  "permission denied"
  "ssl handshake failed"
  "could not write to file"  # contains "could not" but no "resolve...pull request"
)
for fixture in "${negative_fixtures[@]}"; do
  if printf '%s' "$fixture" | grep -qiE "$REGEX"; then
    fail "negative (production regex): '$fixture' falsely classified"
  else
    pass "negative (production regex): '$fixture' correctly NOT classified"
  fi
done

print_summary "$(basename "$0")" "If you change the classification regex in post-compact.sh, update both this test fixtures and the regex literal. Weakening (removing \\s* / requiring literal space / removing -i flag) causes the cycle-6 false-positive regression for close/merge-deleted PRs."
