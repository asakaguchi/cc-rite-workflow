#!/bin/bash
# T-2 (Issue #1017): 4 reviewer (security/database/devops/dependencies) で scope=nit-noted 禁止が明記
#
# Verification:
#   - _reviewer-base.md の Scope Assignment Flowchart 内の Hypothetical Exception カテゴリ節に
#     4 reviewer 全員の禁止が明記される
#   - severity-levels.md の Hypothetical Exception カテゴリ scope 制約節に 4 reviewer 全員が列挙

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
BASE_FILE="$REPO_ROOT/plugins/rite/agents/_reviewer-base.md"
SEVERITY_FILE="$REPO_ROOT/plugins/rite/references/severity-levels.md"

fail_count=0
fail_messages=()

# 1. _reviewer-base.md の Hypothetical Exception 4 reviewer nit-noted 禁止節
if ! grep -q "Hypothetical Exception カテゴリの nit-noted 禁止\|Hypothetical Exception.*nit-noted" "$BASE_FILE"; then
  fail_count=$((fail_count + 1))
  fail_messages+=("FAIL: _reviewer-base.md missing 'Hypothetical Exception ... nit-noted 禁止' section heading")
fi

# 2. 4 reviewer 名がすべて _reviewer-base.md の該当節に登場
for r in security database devops dependencies; do
  if ! awk '/Hypothetical Exception カテゴリの nit-noted 禁止/,/^##[^#]/' "$BASE_FILE" | grep -q "${r}\.md\|${r}-reviewer\|\`${r}\`"; then
    fail_count=$((fail_count + 1))
    fail_messages+=("FAIL: _reviewer-base.md Hypothetical Exception section missing $r reviewer reference")
  fi
done

# 3. severity-levels.md の Hypothetical Exception scope 制約節
if ! grep -q "Hypothetical Exception カテゴリの scope 制約\|Hypothetical Exception.*scope" "$SEVERITY_FILE"; then
  fail_count=$((fail_count + 1))
  fail_messages+=("FAIL: severity-levels.md missing Hypothetical Exception scope 制約 section")
fi

# 4. 4 reviewer 名と nit-noted 禁止記述が severity-levels.md に列挙
for r in security database devops dependencies; do
  if ! awk '/Hypothetical Exception カテゴリの scope 制約/,/^##[^#]/' "$SEVERITY_FILE" | grep -q "${r}\.md\|${r}-reviewer\|\`${r}\`"; then
    fail_count=$((fail_count + 1))
    fail_messages+=("FAIL: severity-levels.md scope 制約 section missing $r reviewer reference")
  fi
done

if [ "$fail_count" -gt 0 ]; then
  printf '%s\n' "${fail_messages[@]}" >&2
  echo "FAILED: $fail_count assertion(s) failed" >&2
  exit 1
fi

echo "PASS: reviewer-hypothetical-nit-noted-ban (4 reviewer nit-noted 禁止 documented in both files)"
