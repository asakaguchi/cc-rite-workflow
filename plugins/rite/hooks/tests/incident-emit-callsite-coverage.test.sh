#!/bin/bash
# incident-emit-callsite-coverage.test.sh
#
# Each WORKFLOW_INCIDENT type must (a) be emitted from at least one caller and
# (b) be accepted by workflow-incident-emit.sh's case allowlist. A generic
# wildcard match elsewhere passes on mere prose mentions, so this test pins
# the type→caller correspondence explicitly. Two failure modes it guards:
#   - emit removed from caller, allowlist still includes type (orphan allowlist)
#   - caller emits a type, allowlist never gets it added (silent runtime reject)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

START_MD="$PLUGIN_ROOT/commands/issue/start.md"
CREATE_MD="$PLUGIN_ROOT/commands/issue/create.md"
CLOSE_MD="$PLUGIN_ROOT/commands/issue/close.md"
READY_MD="$PLUGIN_ROOT/commands/pr/ready.md"
LINT_MD="$PLUGIN_ROOT/commands/lint.md"
GITIGNORE_HEALTH="$PLUGIN_ROOT/hooks/scripts/gitignore-health-check.sh"
POST_COMPACT="$PLUGIN_ROOT/hooks/post-compact.sh"
SESSION_END="$PLUGIN_ROOT/hooks/session-end.sh"
EMIT_SH="$PLUGIN_ROOT/hooks/workflow-incident-emit.sh"
CROSS_SESSION_EMIT="$PLUGIN_ROOT/hooks/_emit-cross-session-incident.sh"
# body_shrinkage_guard_tripped is emitted by the helper itself so the safety
# net is self-emitting (caller cannot observe a guard-tripped exit from exit
# code alone); the previous orchestrator-side emit was unreachable dead code.
BODY_SAFE_UPDATE="$PLUGIN_ROOT/hooks/issue-body-safe-update.sh"

for f in "$START_MD" "$CREATE_MD" "$CLOSE_MD" "$READY_MD" "$LINT_MD" "$GITIGNORE_HEALTH" "$POST_COMPACT" "$SESSION_END" "$EMIT_SH" "$CROSS_SESSION_EMIT" "$BODY_SAFE_UPDATE"; do
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
# Pin per-type emit sites so a removed emit at the caller (e.g. someone deletes
# `--type parent_close_failed` from start.md) fails the test loudly. A union grep
# would pass on mere prose mentions of the type name — false positive.
declare -A INCIDENT_EXPECTED_SITES=(
  [projects_status_update_failed]="$START_MD $READY_MD"
  [projects_status_in_review_missing]="$POST_COMPACT"
  [git_push_failed]="$START_MD"
  [pr_create_failed]="$START_MD"
  [skill_load_failure]="$START_MD"
  [issue_body_fetch_failed]="$START_MD $CREATE_MD"
  [body_shrinkage_guard_tripped]="$BODY_SAFE_UPDATE"
  [sub_issue_zero_iteration_loop]="$CREATE_MD"
  [sub_issue_loop_abort]="$CREATE_MD"
  [issue_branch_link_failed]="$START_MD"
  [local_wm_update_lock_failed]="$START_MD"
  [parent_close_failed]="$START_MD"
  [state_root_toctou_race]="$POST_COMPACT"
  [wiki_ingest_skipped]="$CLOSE_MD"
  [wiki_ingest_failed]="$CLOSE_MD"
  [wiki_ingest_push_failed]="$CLOSE_MD"
  [gitignore_drift]="$GITIGNORE_HEALTH"
  [hook_abnormal_exit]="$LINT_MD"
  [manual_fallback_adopted]="$LINT_MD"
  [cross_session_takeover_refused]="$CROSS_SESSION_EMIT"
  [legacy_state_corrupt]="$CROSS_SESSION_EMIT"
)

for type in "${!INCIDENT_EXPECTED_SITES[@]}"; do
  expected_paths="${INCIDENT_EXPECTED_SITES[$type]}"
  found_in=""
  missing_from=""
  for path in $expected_paths; do
    if grep -qF "$type" "$path" 2>/dev/null; then
      found_in="${found_in} $(basename "$path")"
    else
      missing_from="${missing_from} $(basename "$path")"
    fi
  done
  if [ -z "$missing_from" ]; then
    pass "type '$type' emitted at all expected sites:${found_in}"
  else
    fail "type '$type' missing from expected emit site(s):${missing_from} (found in:${found_in:- none})"
  fi
done

# Lifecycle types fire from multiple sites in start.md; presence at one site is
# not enough — a partial removal (2 of 3 callsites) would silently regress the
# audit trail for the missing path. Pin a lower bound count for each type that
# has more than one expected emit site.
declare -A INCIDENT_MIN_COUNT=(
  [local_wm_update_lock_failed]=3
  [parent_close_failed]=1
  [issue_branch_link_failed]=1
  [git_push_failed]=1
  [pr_create_failed]=1
  [skill_load_failure]=1
)
for type in "${!INCIDENT_MIN_COUNT[@]}"; do
  expected_min="${INCIDENT_MIN_COUNT[$type]}"
  actual=$(grep -cE -- "--type[[:space:]]+$type\\b|type=$type\\b" "$START_MD" 2>/dev/null || echo 0)
  if [ "$actual" -ge "$expected_min" ]; then
    pass "type '$type' callsite count $actual >= expected minimum $expected_min"
  else
    fail "type '$type' callsite count $actual < expected minimum $expected_min (partial removal?)"
  fi
done

echo "=== Phase 5: workflow-incident-emit.sh runtime accept for each callsite type ==="
# Static grep at Phase 4 sees only the caller side; it cannot detect drift in
# emit.sh's case allowlist (caller writes a new type, allowlist never gets it
# added → silent reject at runtime). Run each type through emit.sh to verify
# both sides agree.
for type in "${!INCIDENT_EXPECTED_SITES[@]}"; do
  if bash "$EMIT_SH" --type "$type" --details "runtime accept test" --pr-number 0 >/dev/null 2>&1; then
    pass "emit.sh accepts type '$type' at runtime (exit 0)"
  else
    fail "emit.sh rejects type '$type' at runtime — case allowlist drift detected"
  fi
done

# Negative case: 未登録 type が rejected されることを担保する (whitelist の意味喪失を検出)
if bash "$EMIT_SH" --type "definitely_not_a_real_type" --details test --pr-number 0 >/dev/null 2>&1; then
  fail "emit.sh accepts unknown type — whitelist no longer functions as guard"
else
  pass "emit.sh rejects unknown type (whitelist functions as guard)"
fi

print_summary "$(basename "$0")" "Caller-specific WORKFLOW_INCIDENT emit literals must remain in their respective callers. If you remove or rename an emit type, update both this test and the consuming start.md ステップ 8.5 Workflow Incident Detection table."
