#!/bin/bash
# T-4: severity × scope マトリクスの禁止セルが schema 1.1.0 Cross-field invariants と
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
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
SEVERITY_FILE="$REPO_ROOT/plugins/rite/references/severity-levels.md"
SCHEMA_FILE="$REPO_ROOT/plugins/rite/references/review-result-schema.md"

# 1. severity-levels.md に Severity × Scope Matrix 節が存在
assert_grep "severity-levels.md: Severity × Scope Matrix section heading" \
  "$SEVERITY_FILE" \
  '^## Severity × Scope Matrix|Severity × Scope Matrix'

# 2. matrix 節内に 5 severity 等級が列挙
for sev in "CRITICAL" "HIGH" "MEDIUM" "LOW-MEDIUM" "LOW"; do
  assert_grep_in_section "matrix section: severity '$sev' listed" \
    "$SEVERITY_FILE" \
    'Severity × Scope Matrix' \
    '^## [^S]' \
    "\\*\\*${sev}\\*\\*"
done

# 3. 禁止セル CRITICAL × follow-up / nit-noted が記述
assert_grep_in_section "matrix section: CRITICAL × follow-up/nit-noted 禁止 cell" \
  "$SEVERITY_FILE" \
  'Severity × Scope Matrix' \
  '^## [^S]' \
  'CRITICAL.*`follow-up`.*`nit-noted`|follow-up.*nit-noted.*CRITICAL'

# 4. 禁止セル HIGH × nit-noted が記述
assert_grep_in_section "matrix section: HIGH × nit-noted 禁止 cell" \
  "$SEVERITY_FILE" \
  'Severity × Scope Matrix' \
  '^## [^S]' \
  'HIGH.*`nit-noted`'

# 5. 禁止セル LOW × follow-up が記述
assert_grep_in_section "matrix section: LOW × follow-up 禁止 cell" \
  "$SEVERITY_FILE" \
  'Severity × Scope Matrix' \
  '^## [^S]' \
  'LOW.*`follow-up`|`follow-up`.*LOW'

# 6. schema 1.1.0 Cross-field invariant #4 (CRITICAL/HIGH × nit-noted FAIL) の本体定義を確認
#    Cross-field invariants セクション内に絞った section-scoped grep で、
#    L127 等の forward-pointer 記述による false-pass を排除する。
#    番号付き定義 "4. **`severity ∈ {CRITICAL, HIGH}` ∧ `scope == \"nit-noted\"` 禁止**" を anchor とする。
assert_grep_in_section "schema 1.1.0 Cross-field invariants: item #4 body definition (CRITICAL/HIGH × nit-noted FAIL)" \
  "$SCHEMA_FILE" \
  '^### Cross-field invariants' \
  '^## ' \
  '^4\.[[:space:]]+\*\*.*severity.*CRITICAL.*HIGH.*scope.*nit-noted.*禁止'

# 7. jq invariant 実行: 禁止セル CRITICAL × nit-noted を含む JSON が FAIL する
jq_test_json='{"findings":[{"severity":"CRITICAL","scope":"nit-noted","file_line":"src/x.ts:1"},{"severity":"MEDIUM","scope":"current-pr","file_line":"src/y.ts:2"}]}'
jq_result=$(printf '%s' "$jq_test_json" | jq '[.findings[] | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length == 0')
assert "jq invariant: CRITICAL × nit-noted forbidden cell detected (expected false)" \
  "false" \
  "$jq_result"

# 8. jq invariant: 許容セル (MEDIUM × follow-up / LOW-MEDIUM × nit-noted) は PASS
jq_test_json2='{"findings":[{"severity":"MEDIUM","scope":"follow-up","file_line":"src/x.ts:1"},{"severity":"LOW-MEDIUM","scope":"nit-noted","file_line":"src/y.ts:2"}]}'
jq_result2=$(printf '%s' "$jq_test_json2" | jq '[.findings[] | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length == 0')
assert "jq invariant: valid combinations accepted (MEDIUM × follow-up, LOW-MEDIUM × nit-noted, expected true)" \
  "true" \
  "$jq_result2"

if ! print_summary "$(basename "$0")"; then
  exit 1
fi
