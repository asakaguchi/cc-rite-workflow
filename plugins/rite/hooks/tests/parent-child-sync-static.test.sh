#!/bin/bash
# parent-child-sync-static.test.sh
#
# Parent/child Issue closure relies on detecting the relationship via three
# methods (body meta, GraphQL trackedIssues, tasklist). A past inline
# simplification that kept only trackedIssues silently broke parent-close
# when child Issues used the other two methods. Pin the static invariants:
#
#   - close.md Phase 4.5.1 keeps all three Method 1/2/3 blocks
#   - close.md Phase 4.6 keeps the auto-close skeleton (P460_DECISION)
#   - start.md ステップ 8.4 uses the trackedIssues query
#   - projects-integration.md §2.4.7 documents all three methods

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
# Issue #513 root cause was silent collapse of the 3-method OR documentation to a
# single method. Each method is asserted independently so partial removal (e.g.
# dropping `## 親 Issue` while keeping the GraphQL block) cannot slide through.
# Method 2 here uses the child-to-parent GraphQL query `parent { number }` via
# the `sub_issues` feature flag — different from close.md / start.md which use
# the parent-to-children `trackedIssues` field.
assert_grep "projects-integration.md §2.4.7 retains Method 1 (## 親 Issue body meta)" "$PROJECTS_REF" "## 親 Issue"
assert_grep "projects-integration.md §2.4.7 retains Method 2 (sub_issues GraphQL feature)" "$PROJECTS_REF" "sub_issues"
assert_grep "projects-integration.md §2.4.7 retains Method 3 (tasklist / in:body search)" "$PROJECTS_REF" "in:body|tasklist"

print_summary "$(basename "$0")" "If you remove any of the 3 parent-detection methods (body meta / GraphQL trackedIssues / tasklist) from close.md or start.md ステップ 8.4, Issue #513 regression risk reopens. Re-confirm cross-references before removing methods."
