#!/bin/bash
# link-sub-issue.test.sh — CG-4 (PR #1079 verified-review)
#
# Purpose:
#   `scripts/link-sub-issue.sh` の static invariant を pin する。実際の gh CLI 呼び出しは
#   mock していないため runtime path は cover しないが、placeholder rejection (引数に
#   `{owner}` / `{repo}` 等が残ったまま渡されたら fail-fast)、引数数 validation、
#   JSON output skeleton の存在を確認する。
#
# Caller-side: create.md ステップ 5.4 で Variant B JSON fallback (`|| link_result="{...}"`)
# が JSON valid なエスケープを残しているかも確認する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
TARGET="$PLUGIN_ROOT/scripts/link-sub-issue.sh"
CREATE_MD="$PLUGIN_ROOT/commands/issue/create.md"
HANDLER_REF="$PLUGIN_ROOT/references/sub-issue-link-handler.md"

for f in "$TARGET" "$CREATE_MD" "$HANDLER_REF"; do
  [ -f "$f" ] || { echo "ERROR: required file not found: $f" >&2; exit 1; }
done

echo "=== Phase 1: link-sub-issue.sh placeholder rejection ==="
# Unsubstituted Markdown placeholder must be rejected fail-fast (no silent gh API call).
rc=0
out=$(bash "$TARGET" '{owner}' 'repo' '1' '2' 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then
  pass "TC-01 unsubstituted owner placeholder → non-zero exit (got $rc)"
else
  fail "TC-01 unsubstituted owner placeholder silently passed (exit 0)"
fi

rc=0
out=$(bash "$TARGET" 'B16B1RD' '{repo}' '1' '2' 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then
  pass "TC-02 unsubstituted repo placeholder → non-zero exit"
else
  fail "TC-02 unsubstituted repo placeholder silently passed"
fi

echo "=== Phase 2: link-sub-issue.sh argument count validation ==="
rc=0
out=$(bash "$TARGET" 'owner' 'repo' '1' 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then
  pass "TC-03 missing 4th positional arg → non-zero exit"
else
  fail "TC-03 missing 4th positional arg silently passed"
fi

echo "=== Phase 3: create.md Variant B JSON fallback safety ==="
# PR #1079 review (code-reviewer Important #4 対応): 旧手書き JSON 構築は quote escape で
# 破綻するリスクがあったため、`jq -n --arg err "$link_result" ...` パターンに統一済み。
# 本 assert は: (a) "link-sub-issue.sh fatal exit" message が残っている (b) jq -n パターンで
# 構築されている (c) `jq -n` で実際に生成した JSON が parse 可能。
assert_grep "create.md Variant B fallback has JSON status=failed" "$CREATE_MD" 'link-sub-issue\.sh fatal exit'
assert_grep "create.md Variant B fallback builds JSON via jq -n" "$CREATE_MD" 'link_result=.\(jq -n'

# Runtime sanity: the fallback pattern's output JSON must parse via jq.
# Simulate the fallback locally with a stderr containing tricky characters.
trick_err='gh: "Could not resolve" to PullRequest with "id"='
fallback_json=$(jq -n --arg err "$trick_err" '{status:"failed",message:"link-sub-issue.sh fatal exit",warnings:[$err]}')
if printf '%s' "$fallback_json" | jq -e . >/dev/null 2>&1; then
  pass "TC-04 fallback JSON via jq -n parses cleanly even with quoted stderr"
else
  fail "TC-04 fallback JSON failed to parse: $fallback_json"
fi
if [ "$(printf '%s' "$fallback_json" | jq -r '.status')" = "failed" ]; then
  pass "TC-05 fallback JSON has status=failed"
else
  fail "TC-05 fallback JSON missing status=failed: $fallback_json"
fi

echo "=== Phase 4: handler reference enumerates active caller (create.md) ==="
assert_grep "sub-issue-link-handler.md references active caller create.md" "$HANDLER_REF" "create\.md.*ステップ 5\.4"

echo "=== Phase 5: link-sub-issue.sh emits JSON status field ==="
# script source 中に `"status"` キーが含まれること (output JSON skeleton 確認)
assert_grep "link-sub-issue.sh emits JSON with status field" "$TARGET" '"status"'
assert_grep "link-sub-issue.sh handles ok / already-linked / failed statuses" "$TARGET" "ok|already-linked|failed"

print_summary "$(basename "$0")" "If you change the link-sub-issue.sh argument contract (4 positional args), JSON output schema, or remove the placeholder rejection, update both this test and the consuming create.md ステップ 5.4 + sub-issue-link-handler.md."
