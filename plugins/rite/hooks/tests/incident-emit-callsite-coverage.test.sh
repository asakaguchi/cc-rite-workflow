#!/bin/bash
# incident-emit-callsite-coverage.test.sh — CG-1 (PR #1079 verified-review re-port)
#
# Purpose:
#   旧 projects-status-incident-emit.test.sh (PR #1079 で削除) のカバレッジを flat
#   workflow 用に復元する。WORKFLOW_INCIDENT emit のうち、`projects_status_update_failed`
#   / `projects_status_in_review_missing` 等 caller-specific type は、対応 caller の
#   markdown / shell に必ず存在しなければならない。
#
#   `start-md-sentinel-coverage.test.sh` の generic `workflow-incident-emit.sh --type`
#   一致 assert は wildcard で通過するため、type-by-phase の対応をピンする必要がある。
#
# Coverage:
#   - start.md ステップ 8.3 / 8.4 に `projects_status_update_failed` emit が 1+ 存在
#   - pr/ready.md Phase 4.2 に `projects_status_update_failed` emit が存在
#   - post-compact.sh に `projects_status_in_review_missing` emit が存在
#   - start.md の git push 失敗時に `git_push_failed` emit が存在
#   - start.md の PR 作成失敗時に `pr_create_failed` emit が存在 (bash block 内)
#   - start.md の lint sentinel drop に対する `skill_load_failure` emit が存在
#   - workflow-incident-emit.sh が `projects_status_update_failed` / `projects_status_in_review_missing`
#     / `git_push_failed` / `pr_create_failed` / `skill_load_failure` 等の type を accept する

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

START_MD="$PLUGIN_ROOT/commands/issue/start.md"
CREATE_MD="$PLUGIN_ROOT/commands/issue/create.md"
READY_MD="$PLUGIN_ROOT/commands/pr/ready.md"
POST_COMPACT="$PLUGIN_ROOT/hooks/post-compact.sh"
EMIT_SH="$PLUGIN_ROOT/hooks/workflow-incident-emit.sh"

for f in "$START_MD" "$CREATE_MD" "$READY_MD" "$POST_COMPACT" "$EMIT_SH"; do
  [ -f "$f" ] || { echo "ERROR: required file not found: $f" >&2; exit 1; }
done

echo "=== Phase 1: start.md caller-specific emit literals ==="
# Callsite 2 (ステップ 8.3 In Review) — projects_status_update_failed
count=$(grep -c "projects_status_update_failed" "$START_MD" || true)
if [ "$count" -ge 2 ]; then
  pass "start.md has projects_status_update_failed emit (>=2 occurrences for skipped_not_in_project + failed arms)"
else
  fail "start.md missing projects_status_update_failed emit (expected >=2, got $count)"
fi

# git push failure
assert_grep "start.md emits git_push_failed in push failure path" "$START_MD" "git_push_failed"

# PR create failed — bash block within H-2 fix (search for type=pr_create_failed literal anywhere)
assert_grep "start.md emits pr_create_failed via workflow-incident-emit.sh" "$START_MD" "type pr_create_failed"

# Skill load failure (default sentinel drop)
assert_grep "start.md emits skill_load_failure on lint/review/fix/ready sentinel drop" "$START_MD" "skill_load_failure"

echo "=== Phase 2: pr/ready.md primary emit literal ==="
assert_grep "ready.md emits projects_status_update_failed in Phase 4.2" "$READY_MD" "projects_status_update_failed"

echo "=== Phase 3: post-compact.sh reconciliation emit literal ==="
assert_grep "post-compact.sh emits projects_status_in_review_missing" "$POST_COMPACT" "projects_status_in_review_missing"

echo "=== Phase 4: workflow-incident-emit.sh accepts canonical types ==="
# emit script のヘルプ / case 文に各 type が現れる (ホワイトリスト or accept)
for type in projects_status_update_failed projects_status_in_review_missing git_push_failed pr_create_failed skill_load_failure issue_body_fetch_failed body_shrinkage_guard_tripped sub_issue_zero_iteration_loop; do
  if grep -qF "$type" "$EMIT_SH" "$START_MD" "$CREATE_MD" 2>/dev/null; then
    pass "type '$type' is referenced in emit.sh / start.md / create.md"
  else
    fail "type '$type' is not referenced in emit.sh / start.md / create.md (orphan type registration?)"
  fi
done

print_summary "$(basename "$0")" "Caller-specific WORKFLOW_INCIDENT emit literals must remain in their respective callers. If you remove or rename an emit type, update both this test and the consuming start.md ステップ 8.5 Workflow Incident Detection table."
