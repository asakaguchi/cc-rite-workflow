#!/bin/bash
# T-1 (Issue #1017): 13 reviewer agent すべて _reviewer-base.md を継承し scope 列を Output Format に持つ
#
# Verification:
#   - _reviewer-base.md の Output Format テーブルが 5 列 (重要度|スコープ|ファイル:行|内容|推奨対応)
#   - 13 reviewer agent (api/code-quality/database/dependencies/devops/error-handling/frontend/
#     performance/prompt-engineer/security/tech-writer/test/type-design) すべての example 表が 5 列

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
AGENTS_DIR="$REPO_ROOT/plugins/rite/agents"

fail_count=0
fail_messages=()

# 1. _reviewer-base.md に 5 列ヘッダーが存在することを確認
base_file="$AGENTS_DIR/_reviewer-base.md"
if [ ! -f "$base_file" ]; then
  fail_count=$((fail_count + 1))
  fail_messages+=("FAIL: $base_file not found")
elif ! grep -q '| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |' "$base_file"; then
  fail_count=$((fail_count + 1))
  fail_messages+=("FAIL: _reviewer-base.md does not contain 5-column header (重要度|スコープ|ファイル:行|内容|推奨対応)")
fi

# 2. _reviewer-base.md の旧 4 列ヘッダーがどこかに残存していないか
if grep -qE '\| 重要度 \| ファイル:行 \| 内容 \| 推奨対応 \|' "$base_file"; then
  fail_count=$((fail_count + 1))
  fail_messages+=("FAIL: _reviewer-base.md still contains 4-column header (drift)")
fi

# 3. 13 reviewer agent の example 表が 5 列か
reviewers=(
  api-reviewer
  code-quality-reviewer
  database-reviewer
  dependencies-reviewer
  devops-reviewer
  error-handling-reviewer
  frontend-reviewer
  performance-reviewer
  prompt-engineer-reviewer
  security-reviewer
  tech-writer-reviewer
  test-reviewer
  type-design-reviewer
)

for r in "${reviewers[@]}"; do
  f="$AGENTS_DIR/$r.md"
  if [ ! -f "$f" ]; then
    fail_count=$((fail_count + 1))
    fail_messages+=("FAIL: $r.md not found")
    continue
  fi
  if ! grep -q '| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |' "$f"; then
    fail_count=$((fail_count + 1))
    fail_messages+=("FAIL: $r.md missing 5-column header")
  fi
  if grep -qE '\| 重要度 \| ファイル:行 \| 内容 \| 推奨対応 \|' "$f"; then
    fail_count=$((fail_count + 1))
    fail_messages+=("FAIL: $r.md still has 4-column header (drift)")
  fi
done

if [ "$fail_count" -gt 0 ]; then
  printf '%s\n' "${fail_messages[@]}" >&2
  echo "FAILED: $fail_count assertion(s) failed" >&2
  exit 1
fi

echo "PASS: reviewer-scope-column-symmetry (13 reviewers + base have 5-column scope header)"
