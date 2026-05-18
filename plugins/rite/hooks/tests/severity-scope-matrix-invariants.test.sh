#!/bin/bash
# T-4 (Issue #1017): severity × scope マトリクスの禁止セルが schema 1.1.0 Cross-field invariants と
# 整合しているか jq invariant で検証
#
# Verification:
#   - severity-levels.md に Severity × Scope Matrix 節が存在
#   - matrix で CRITICAL × follow-up / nit-noted、HIGH × nit-noted、LOW × follow-up が「禁止 scope」
#     として記述
#   - schema 1.1.0 Cross-field invariant #4 (CRITICAL/HIGH × nit-noted FAIL) と matrix が整合
#   - jq で禁止セルを実 finding に対して阻止できることを確認

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SEVERITY_FILE="$REPO_ROOT/plugins/rite/references/severity-levels.md"
SCHEMA_FILE="$REPO_ROOT/plugins/rite/references/review-result-schema.md"

fail_count=0
fail_messages=()

# 1. severity-levels.md に Severity × Scope Matrix 節が存在
if ! grep -q "^## Severity × Scope Matrix\|Severity × Scope Matrix" "$SEVERITY_FILE"; then
  fail_count=$((fail_count + 1))
  fail_messages+=("FAIL: severity-levels.md missing Severity × Scope Matrix section heading")
fi

# 2. matrix 節内に 5 severity 等級が列挙
matrix_section=$(awk '/Severity × Scope Matrix/,/^## [^S]/' "$SEVERITY_FILE")
for sev in "CRITICAL" "HIGH" "MEDIUM" "LOW-MEDIUM" "LOW"; do
  if ! printf '%s\n' "$matrix_section" | grep -qE "\*\*${sev}\*\*"; then
    fail_count=$((fail_count + 1))
    fail_messages+=("FAIL: matrix section missing severity '$sev'")
  fi
done

# 3. 禁止セル CRITICAL × follow-up / nit-noted が記述
if ! printf '%s\n' "$matrix_section" | grep -qE "CRITICAL.*\`follow-up\`.*\`nit-noted\`|follow-up.*nit-noted.*CRITICAL"; then
  fail_count=$((fail_count + 1))
  fail_messages+=("FAIL: matrix section missing CRITICAL × follow-up/nit-noted 禁止 cell")
fi

# 4. 禁止セル HIGH × nit-noted が記述
if ! printf '%s\n' "$matrix_section" | grep -qE "HIGH.*\`nit-noted\`"; then
  fail_count=$((fail_count + 1))
  fail_messages+=("FAIL: matrix section missing HIGH × nit-noted 禁止 cell")
fi

# 5. 禁止セル LOW × follow-up が記述
if ! printf '%s\n' "$matrix_section" | grep -qE "LOW.*\`follow-up\`|\`follow-up\`.*LOW"; then
  fail_count=$((fail_count + 1))
  fail_messages+=("FAIL: matrix section missing LOW × follow-up 禁止 cell")
fi

# 6. schema 1.1.0 Cross-field invariant #4 (CRITICAL/HIGH × nit-noted FAIL) の本体定義を確認
#    Cross-field invariants セクション内に絞った section-scoped grep で、
#    L127 等の forward-pointer 記述による false-pass を排除する。
#    番号付き定義 "4. **`severity ∈ {CRITICAL, HIGH}` ∧ `scope == \"nit-noted\"` 禁止**" を anchor とする。
cross_field_section=$(awk '/^### Cross-field invariants/,/^## /' "$SCHEMA_FILE")
if ! printf '%s\n' "$cross_field_section" | grep -qE '^4\.\s+\*\*.*severity.*CRITICAL.*HIGH.*scope.*nit-noted.*禁止'; then
  fail_count=$((fail_count + 1))
  fail_messages+=("FAIL: schema 1.1.0 Cross-field invariants section missing item #4 body definition (CRITICAL/HIGH × nit-noted FAIL invariant)")
fi

# 7. jq invariant 実行: 禁止セル CRITICAL × nit-noted を含む JSON が FAIL する
jq_test_json='{"findings":[{"severity":"CRITICAL","scope":"nit-noted","file_line":"src/x.ts:1"},{"severity":"MEDIUM","scope":"current-pr","file_line":"src/y.ts:2"}]}'
jq_result=$(printf '%s' "$jq_test_json" | jq '[.findings[] | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length == 0')
if [ "$jq_result" != "false" ]; then
  fail_count=$((fail_count + 1))
  fail_messages+=("FAIL: jq invariant did not detect CRITICAL × nit-noted forbidden cell (result=$jq_result, expected false)")
fi

# 8. jq invariant: 許容セル (MEDIUM × follow-up / LOW-MEDIUM × nit-noted) は PASS
jq_test_json2='{"findings":[{"severity":"MEDIUM","scope":"follow-up","file_line":"src/x.ts:1"},{"severity":"LOW-MEDIUM","scope":"nit-noted","file_line":"src/y.ts:2"}]}'
jq_result2=$(printf '%s' "$jq_test_json2" | jq '[.findings[] | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length == 0')
if [ "$jq_result2" != "true" ]; then
  fail_count=$((fail_count + 1))
  fail_messages+=("FAIL: jq invariant rejected valid combinations (MEDIUM × follow-up, LOW-MEDIUM × nit-noted, result=$jq_result2, expected true)")
fi

if [ "$fail_count" -gt 0 ]; then
  printf '%s\n' "${fail_messages[@]}" >&2
  echo "FAILED: $fail_count assertion(s) failed" >&2
  exit 1
fi

echo "PASS: severity-scope-matrix-invariants (matrix 禁止セル integrate with schema invariant #4 and jq blocks forbidden combinations)"
