#!/bin/bash
# T-3: Finding Quality Guardrail に scope 自己降格パターン (CRITICAL/HIGH の severity と
# scope の二重 degrade) 検出仕様が記述されているか
#
# Verification:
#   - _reviewer-base.md の Finding Quality Guardrail Filter categories テーブルに
#     scope self-degradation chain (Category #5) が含まれる
#   - severity 自己降格と scope 自己降格を組み合わせた二重 degrade の警告が記述される

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
BASE_FILE="$REPO_ROOT/plugins/rite/agents/_reviewer-base.md"

# 1. Finding Quality Guardrail に Scope self-degradation chain Category が存在
assert_grep "_reviewer-base.md: 'Scope self-degradation chain' or 'scope 自己降格' Guardrail category" \
  "$BASE_FILE" \
  'Scope self-degradation chain|scope 自己降格'

# 2. 二重 degrade パターン (severity 降格 + scope 降格 の連鎖) の記述
assert_grep "_reviewer-base.md: double-degrade (severity + scope) chain example" \
  "$BASE_FILE" \
  '二重 degrade|severity.*scope.*degrade|severity.*降格.*scope.*降格|CRITICAL.*MEDIUM.*nit-noted'

# 3. Finding Quality Guardrail Filter categories テーブルに Category #5 (Scope self-degradation) が存在
assert_grep_in_section "Finding Quality Guardrail filter table: Category #5 (Scope self-degradation chain)" \
  "$BASE_FILE" \
  '## Finding Quality Guardrail' \
  '^## [^F]' \
  '\| 5 \|.*[Ss]cope|\| 5 \|.*scope 自己降格'

# 4. original_severity フィールド (schema 1.1.0) への参照があるか (修正方針の根拠)
assert_grep "_reviewer-base.md: original_severity field reference (schema 1.1.0 trace)" \
  "$BASE_FILE" \
  'original_severity'

if ! print_summary "$(basename "$0")"; then
  exit 1
fi
