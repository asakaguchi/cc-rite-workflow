#!/bin/bash
# T-2: 4 reviewer (security/database/devops/dependencies) で scope=nit-noted 禁止が明記
#
# Verification:
#   - _reviewer-base.md の Scope Assignment Flowchart 内の Hypothetical Exception カテゴリ節に
#     4 reviewer 全員の禁止が明記される
#   - severity-levels.md の Hypothetical Exception カテゴリ scope 制約節に 4 reviewer 全員が列挙

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
BASE_FILE="$REPO_ROOT/plugins/rite/agents/_reviewer-base.md"
SEVERITY_FILE="$REPO_ROOT/plugins/rite/references/severity-levels.md"

# Note: BASE_FILE (_reviewer-base.md) と SEVERITY_FILE (severity-levels.md) は意図的に異なる
# heading 名を持つ (前者は "nit-noted 禁止"、後者は "scope 制約")。これは責務の差を反映: BASE_FILE は
# 「nit-noted を禁止する」という制約を、SEVERITY_FILE は「scope 軸の許容/禁止 matrix」を主題とする。
# テストは両方の正確な heading を独立に literal match で検証する。

# 1. _reviewer-base.md の Hypothetical Exception 4 reviewer nit-noted 禁止節 (literal heading 固定)
assert_grep "_reviewer-base.md: '### Hypothetical Exception カテゴリの nit-noted 禁止' heading" \
  "$BASE_FILE" \
  '^### Hypothetical Exception カテゴリの nit-noted 禁止$'

# 2. 4 reviewer 名がすべて _reviewer-base.md の該当節に登場
for r in security database devops dependencies; do
  assert_grep_in_section "_reviewer-base.md Hypothetical Exception section: $r reviewer reference" \
    "$BASE_FILE" \
    '^### Hypothetical Exception カテゴリの nit-noted 禁止$' \
    '^##[^#]' \
    "${r}\\.md|${r}-reviewer|\`${r}\`"
done

# 3. severity-levels.md の Hypothetical Exception scope 制約節 (literal heading 固定)
assert_grep "severity-levels.md: '### Hypothetical Exception カテゴリの scope 制約' heading" \
  "$SEVERITY_FILE" \
  '^### Hypothetical Exception カテゴリの scope 制約$'

# 4. 4 reviewer 名と nit-noted 禁止記述が severity-levels.md に列挙
for r in security database devops dependencies; do
  assert_grep_in_section "severity-levels.md scope 制約 section: $r reviewer reference" \
    "$SEVERITY_FILE" \
    '^### Hypothetical Exception カテゴリの scope 制約$' \
    '^##[^#]' \
    "${r}\\.md|${r}-reviewer|\`${r}\`"
done

if ! print_summary "$(basename "$0")"; then
  exit 1
fi
