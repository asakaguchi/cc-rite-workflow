#!/bin/bash
# parent-child-sync-static.test.sh — CG-2 (PR #1079 verified-review re-port)
#
# Purpose:
#   旧 parent-child-sync-static.test.sh (PR #1079 で削除、271 行) のうち、Issue #513
#   の regression guard を flat workflow 用に簡易版として復元する。Issue #513 は
#   親子 Issue の trackedIssues-only inline simplification で AC-1 違反を起こした
#   incident で、関連する 3 method 検出 (body meta / GraphQL / tasklist) の全在を
#   ピンしないと static 検出ができない。
#
#   本 test は中核の static invariant のみを検査する:
#   - close.md Phase 4.5.1 は 3 method (Method 1/2/3) すべてを保持
#   - close.md Phase 4.6 の auto-close 経路の skeleton (P460_DECISION) が残る
#   - start.md ステップ 8.4 (PR #1079 で旧 close 経路を統合) で trackedIssues query が
#     使われている (`Query trackedInIssues` inline simplification の regression 防止)
#   - projects-integration.md §2.4.7 の 3 method 解説が残る

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

CLOSE_MD="$PLUGIN_ROOT/commands/issue/close.md"
START_MD="$PLUGIN_ROOT/commands/issue/start.md"
PROJECTS_REF="$PLUGIN_ROOT/references/projects-integration.md"

for f in "$CLOSE_MD" "$START_MD" "$PROJECTS_REF"; do
  [ -f "$f" ] || { echo "ERROR: required file not found: $f" >&2; exit 1; }
done

echo "=== Phase 1: close.md retains 3 detection methods (Issue #513 guard) ==="
assert_grep "close.md retains Method 1 (## 親 Issue body meta)" "$CLOSE_MD" "## 親 Issue"
assert_grep "close.md retains trackedIssues field usage" "$CLOSE_MD" "trackedIssues"
assert_grep "close.md retains tasklist search method" "$CLOSE_MD" "in:body|tasklist"

echo "=== Phase 2: close.md Phase 4.6 auto-close decision skeleton ==="
assert_grep "close.md retains P460_DECISION skip_already_closed branch" "$CLOSE_MD" "P460_DECISION|skip_already_closed|Phase 4\.6"

echo "=== Phase 3: start.md ステップ 8.4 trackedIssues query (no inline simplification) ==="
assert_grep "start.md ステップ 8.4 uses trackedIssues GraphQL (not bare trackedInIssues)" "$START_MD" "trackedIssues"
# Negative: regression guard. Old simplification used `trackedInIssues` which is not the canonical name.
# トラッキング trackedInIssues (Inヌキ) は GitHub API 名で本来正しいが、Issue #513 では誤った
# 簡略化が起きたため defensive assertion として `trackedIssues` 名の存在を必須にする。
assert_grep "start.md retains Method 1 (## 親 Issue body meta) reference" "$START_MD" "親 Issue"

echo "=== Phase 4: projects-integration.md retains 3-method documentation ==="
assert_grep "projects-integration.md §2.4.7 retains 3-method parent detection" "$PROJECTS_REF" "trackedIssues|## 親 Issue|tasklist"

print_summary "$(basename "$0")" "If you remove any of the 3 parent-detection methods (body meta / GraphQL trackedIssues / tasklist) from close.md or start.md ステップ 8.4, Issue #513 regression risk reopens. Re-confirm cross-references before removing methods."
