#!/bin/bash
# T-3 (Issue #1017): Finding Quality Guardrail に scope 自己降格パターン (CRITICAL/HIGH の severity と
# scope の二重 degrade) 検出仕様が記述されているか
#
# Verification:
#   - _reviewer-base.md の Finding Quality Guardrail Filter categories テーブルに
#     scope self-degradation chain (Category #5) が含まれる
#   - severity 自己降格と scope 自己降格を組み合わせた二重 degrade の警告が記述される

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
BASE_FILE="$REPO_ROOT/plugins/rite/agents/_reviewer-base.md"

fail_count=0
fail_messages=()

# 1. Finding Quality Guardrail に Scope self-degradation chain Category が存在
if ! grep -q "Scope self-degradation chain\|scope 自己降格" "$BASE_FILE"; then
  fail_count=$((fail_count + 1))
  fail_messages+=("FAIL: _reviewer-base.md missing 'Scope self-degradation chain' Guardrail category")
fi

# 2. 二重 degrade パターン (severity 降格 + scope 降格 の連鎖) の記述
if ! grep -qE "二重 degrade|severity.*scope.*degrade|severity.*降格.*scope.*降格|CRITICAL.*MEDIUM.*nit-noted" "$BASE_FILE"; then
  fail_count=$((fail_count + 1))
  fail_messages+=("FAIL: _reviewer-base.md missing double-degrade (severity + scope) chain example")
fi

# 3. Finding Quality Guardrail Filter categories テーブルに Category #5 (Scope self-degradation) が
#    存在する (テーブル内で 5 行目以降に scope 関連 entry がある)
guardrail_section=$(awk '/## Finding Quality Guardrail/,/^## [^F]/' "$BASE_FILE")
if ! printf '%s\n' "$guardrail_section" | grep -qE '\| 5 \|.*[Ss]cope|\| 5 \|.*scope 自己降格'; then
  fail_count=$((fail_count + 1))
  fail_messages+=("FAIL: Finding Quality Guardrail filter table missing Category #5 (Scope self-degradation chain)")
fi

# 4. original_severity フィールド (schema 1.1.0) への参照があるか (修正方針の根拠)
if ! grep -q 'original_severity' "$BASE_FILE"; then
  fail_count=$((fail_count + 1))
  fail_messages+=("FAIL: _reviewer-base.md missing reference to original_severity field (schema 1.1.0 trace)")
fi

if [ "$fail_count" -gt 0 ]; then
  printf '%s\n' "${fail_messages[@]}" >&2
  echo "FAILED: $fail_count assertion(s) failed" >&2
  exit 1
fi

echo "PASS: scope-self-degradation-guardrail (Finding Quality Guardrail extended for scope self-degradation chain)"
