#!/bin/bash
# T-1 (Issue #1017): 13 reviewer agent すべて _reviewer-base.md を継承し scope 列を Output Format に持つ
#
# Verification:
#   - _reviewer-base.md の Output Format テーブルが 5 列 (重要度|スコープ|ファイル:行|内容|推奨対応)
#   - 13 reviewer agent (api/code-quality/database/dependencies/devops/error-handling/frontend/
#     performance/prompt-engineer/security/tech-writer/test/type-design) すべての example 表が 5 列

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
AGENTS_DIR="$REPO_ROOT/plugins/rite/agents"

# 1. _reviewer-base.md に 5 列ヘッダーが存在する
base_file="$AGENTS_DIR/_reviewer-base.md"
assert_grep "_reviewer-base.md: 5-column header (重要度|スコープ|ファイル:行|内容|推奨対応)" \
  "$base_file" \
  '\| 重要度 \| スコープ \| ファイル:行 \| 内容 \| 推奨対応 \|'

# 2. _reviewer-base.md の旧 4 列ヘッダーがどこかに残存していないこと
assert_not_grep "_reviewer-base.md: 4-column header drift (must not exist)" \
  "$base_file" \
  '\| 重要度 \| ファイル:行 \| 内容 \| 推奨対応 \|'

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
  # File-existence guard (Issue #1048 → Issue #1051): assert_grep / assert_not_grep は
  # それぞれ独立にファイル不在チェックを行うため、不在時には 1 reviewer = 2 fail message
  # に膨張する。assert_file_exists_or_fail で 1 件 fail + caller の `|| continue` で
  # 後続 assertion を skip し、原本の「1 reviewer = 1 fail」挙動を維持する
  # (Issue #1051 で _test-helpers.sh 側に共通化済)。
  assert_file_exists_or_fail "$r.md" "$f" || continue
  assert_grep "$r.md: 5-column header present" \
    "$f" \
    '\| 重要度 \| スコープ \| ファイル:行 \| 内容 \| 推奨対応 \|'
  assert_not_grep "$r.md: 4-column header drift (must not exist)" \
    "$f" \
    '\| 重要度 \| ファイル:行 \| 内容 \| 推奨対応 \|'
done

if ! print_summary "$(basename "$0")"; then
  exit 1
fi
